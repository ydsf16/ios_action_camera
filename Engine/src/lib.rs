// SPDX-License-Identifier: GPL-3.0-or-later
//! Thin C boundary around pinned Gyroflow. All frame and gyro times are video-relative.
use gyroflow_core::{StabilizationManager, gyro_source::{FileMetadata, LensParams, TimeIMU},
    gpu::{Buffers, BufferDescription, BufferSource}, stabilization::BGRA8};
use serde::Deserialize;
use std::{ffi::{c_char, CStr}, panic::{catch_unwind, AssertUnwindSafe}};

#[derive(Deserialize)]
struct Frame { timestamp_us: i64, k: [f64; 9] }
#[derive(Deserialize)]
struct Gyro { timestamp_ms: f64, gyro: [f64; 3] }
#[derive(Deserialize, Clone)]
#[serde(default, rename_all = "camelCase")]
struct Options { strength: f64, max_crop: f64, dynamic_crop: bool, allow_black_borders: bool }
impl Default for Options {
    fn default() -> Self { Self { strength: 0.5, max_crop: 2.0, dynamic_crop: true, allow_black_borders: false } }
}
#[derive(Deserialize)]
struct Config {
    #[serde(default)] options: Options,
    #[serde(default = "default_gpu")] use_gpu: bool,
    width: usize, height: usize, output_width: usize, output_height: usize,
    duration_ms: f64, fps: f64, frames: Vec<Frame>, gyro: Vec<Gyro>,
}
fn default_gpu() -> bool { true }
pub struct Engine { transforms: gyroflow_core::stabilization::ComputeParams, use_gpu: bool, manager: StabilizationManager, width: usize, height: usize, ow: usize, oh: usize }

fn create(config: Config) -> Result<Engine, String> {
    if config.width < 4 || config.height < 4 || config.width > 4096 || config.height > 4096
        || config.output_width < 4 || config.output_height < 4 || config.output_width > 2816 || config.output_height > 2816
        || config.output_width > config.width || config.output_height > config.height
        || config.frames.len() < 2 || config.gyro.len() < 3 || !config.duration_ms.is_finite()
        || config.duration_ms <= 0.0 || config.duration_ms > 3_600_000.0 || !(1.0..=120.0).contains(&config.fps) {
        return Err("Invalid input dimensions, timing, or missing motion data".into());
    }
    if config.frames.windows(2).any(|w| w[1].timestamp_us <= w[0].timestamp_us)
        || config.gyro.windows(2).any(|w| w[1].timestamp_ms <= w[0].timestamp_ms)
        || config.frames.iter().any(|f| f.k.iter().any(|x| !x.is_finite()) || f.k[0] <= 0.0 || f.k[4] <= 0.0)
        || config.gyro.iter().any(|g| !g.timestamp_ms.is_finite() || g.gyro.iter().any(|x| !x.is_finite())) {
        return Err("Non-monotonic timestamps or invalid calibration values".into());
    }
    if !config.options.strength.is_finite() || !(0.0..=1.0).contains(&config.options.strength)
        || !config.options.max_crop.is_finite() || !(1.0..=5.0).contains(&config.options.max_crop) {
        return Err("Invalid stabilization options".into());
    }
    let manager = StabilizationManager::default();
    // Zooming uses a nominal video grid; image processing is requested by actual PTS.
    let frame_count = (config.duration_ms * config.fps / 1000.0).ceil() as usize;
    manager.init_from_video_data(config.duration_ms, config.fps, frame_count, (config.width, config.height));
    let k = config.frames[config.frames.len()/2].k;
    let lens = serde_json::json!({
        "name":"MotionCam recorded intrinsics (distortion uncalibrated)",
        "calib_dimension":{"w":config.width,"h":config.height},
        "orig_dimension":{"w":config.width,"h":config.height},
        "calibrator_version":"MotionCam-recorded-intrinsics-v1","camera_brand":"Apple","fps":config.fps,"input_horizontal_stretch":1.0,"input_vertical_stretch":1.0,
        "distortion_model":"opencv_standard",
        "fisheye_params":{"camera_matrix":[[k[0],k[1],k[2]],[k[3],k[4],k[5]],[k[6],k[7],k[8]]],"distortion_coeffs":[0,0,0,0,0,0,0,0]}
    });
    manager.load_lens_profile(&lens.to_string()).map_err(|e| format!("Lens: {e:?}"))?;
    let mut metadata = FileMetadata::default();
    metadata.imu_orientation = Some("XYZ".into());
    metadata.has_accurate_timestamps = true;
    metadata.detected_source = Some("MotionCam".into());
    // Gyroflow internal IMUData expects degrees/s. Convert here, not in the recording.
    metadata.raw_imu = config.gyro.iter().map(|g| TimeIMU {
        timestamp_ms: g.timestamp_ms,
        gyro: Some(g.gyro.map(f64::to_degrees)), accl: None, magn: None,
    }).collect();
    for frame in &config.frames {
        metadata.lens_params.insert(frame.timestamp_us, LensParams {camera_matrix: Some(frame.k), ..Default::default()});
    }
    {
        let mut gyro = manager.gyro.write();
        gyro.init_from_params(&manager.params.read());
        gyro.integration_method = 3;
        gyro.load_from_telemetry(metadata);
        gyro.integrate();
    }
    manager.set_render_params((config.width,config.height),(config.output_width,config.output_height));
    manager.set_smoothing_method(2); // Plain 3D, follows intentional camera turns.
    manager.set_adaptive_zoom(2.0);
    manager.set_max_zoom(0.0, 0); // Apply our explicit crop bound below, independent of output resolution.
    manager.set_frame_readout_time(0.0); // Unknown readout: no rolling-shutter correction.
    manager.set_background_color(nalgebra::Vector4::new(0.0,0.0,0.0,255.0));
    manager.set_horizon_lock(0.0, 0.0);
    manager.set_video_rotation(0.0); // Swift preserves the source track transform.
    let requested_tau = 0.16 * 25.0f64.powf(config.options.strength);
    let limit = 1.0 / config.options.max_crop;
    let mut acceptable = false;
    for factor in [1.0, 0.5, 0.25, 0.1, 0.02] {
        manager.set_smoothing_param("time_constant", requested_tau * factor);
        manager.recompute_blocking();
        let mut params = manager.params.write();
        if params.fovs.is_empty() || params.fovs.iter().any(|f| !f.is_finite() || *f <= 0.0) {
            return Err("Invalid crop calculation".into());
        }
        if config.options.allow_black_borders || params.fovs.iter().all(|f| *f >= limit) {
            for fov in &mut params.fovs {
                *fov = if config.options.dynamic_crop { fov.clamp(limit, 1.0) } else { limit };
            }
            acceptable = true; break;
        }
    }
    if !acceptable { return Err("裁切上限不足：请增大最大裁切，或开启允许黑边。原片已保留。".into()); }
    manager.recompute_undistortion();
    manager.set_device(if config.use_gpu { 0 } else { -1 });
    let transforms = gyroflow_core::stabilization::ComputeParams::from_manager(&manager);
    Ok(Engine { transforms, use_gpu: config.use_gpu, manager, width: config.width, height: config.height, ow: config.output_width, oh: config.output_height })
}

unsafe fn error_out(message: &str, dst: *mut c_char, capacity: usize) {
    if dst.is_null() || capacity == 0 { return; }
    let bytes = message.as_bytes();
    let n = bytes.len().min(capacity - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), dst.cast(), n);
    *dst.add(n) = 0;
}

#[no_mangle]
pub unsafe extern "C" fn mc_engine_create(json: *const c_char, error: *mut c_char, capacity: usize) -> *mut Engine {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if json.is_null() { return Err("Null config".into()); }
        let data = CStr::from_ptr(json).to_bytes();
        let config: Config = serde_json::from_slice(data).map_err(|e| e.to_string())?;
        create(config)
    }));
    match result {
        Ok(Ok(engine)) => Box::into_raw(Box::new(engine)),
        Ok(Err(message)) => { error_out(&message,error,capacity); std::ptr::null_mut() },
        Err(_) => { error_out("Gyroflow initialization failed",error,capacity); std::ptr::null_mut() }
    }
}

#[no_mangle]
pub unsafe extern "C" fn mc_engine_process(engine: *mut Engine, timestamp_us: i64,
    input: *mut u8, input_len: usize, input_stride: usize,
    output: *mut u8, output_len: usize, output_stride: usize,
    error: *mut c_char, capacity: usize) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(),String> {
        if engine.is_null() || input.is_null() || output.is_null() { return Err("Null frame buffer".into()); }
        let e = &*engine;
        if input_stride < e.width*4 || output_stride < e.ow*4
            || input_stride.checked_mul(e.height).map_or(true, |n| n > input_len)
            || output_stride.checked_mul(e.oh).map_or(true, |n| n > output_len) {
            return Err("Invalid pixel buffer bounds".into());
        }
        let mut buffers = Buffers {
            input: BufferDescription { size:(e.width,e.height,input_stride),
                data:BufferSource::Cpu { buffer:std::slice::from_raw_parts_mut(input,input_len) }, ..Default::default() },
            output: BufferDescription { size:(e.ow,e.oh,output_stride),
                data:BufferSource::Cpu { buffer:std::slice::from_raw_parts_mut(output,output_len) }, ..Default::default() },
        };
        let processed = e.manager.process_pixels::<BGRA8>(timestamp_us,None,&mut buffers).map_err(|v|format!("Frame: {v:?}"))?;
        if e.use_gpu && processed.backend != "wgpu" {
            return Err("Metal GPU initialization failed; original video preserved".into());
        }
        Ok(())
    }));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => { error_out(&message,error,capacity); -1 },
        Err(_) => { error_out("Gyroflow frame processing failed",error,capacity); -2 },
    }
}

/// Row-major output-pixel to input-pixel homography, padded to three float4 rows.
/// This fast path is valid only for our current zero-residual-distortion, no-RS contract.
#[no_mangle]
pub unsafe extern "C" fn mc_engine_transform(engine: *mut Engine, timestamp_us: i64,
    output: *mut f32, capacity: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if engine.is_null() || output.is_null() || capacity < 12 { return -1; }
        let e = &*engine;
        let ms = timestamp_us as f64 / 1000.;
        let frame = gyroflow_core::frame_at_timestamp(ms, e.transforms.scaled_fps) as usize;
        let t = gyroflow_core::stabilization::FrameTransform::at_timestamp(&e.transforms, ms, frame);
        let p = &t.kernel_params;
        if e.transforms.digital_lens.is_some() || p.lens_correction_amount != 1.0
            || p.light_refraction_coefficient != 1.0 || p.background_mode != 0
            || t.matrices.len() != 1 || p.k.iter().any(|v| *v != 0.) || !t.mesh_data.is_empty()
            || p.translation2d != [0.,0.] || p.input_horizontal_stretch != 1. || p.input_vertical_stretch != 1.
            || t.matrices[0][9..].iter().any(|v| *v != 0.) { return -2; }
        let r = &t.matrices[0];
        let mut h = [0f32;12];
        for col in 0..3 {
            h[col] = p.f[0]*r[col] + p.c[0]*r[6+col];
            h[4+col] = p.f[1]*r[3+col] + p.c[1]*r[6+col];
            h[8+col] = r[6+col];
        }
        // Gyroflow keeps a logical output canvas at input resolution and maps the
        // actual encoder viewport into it before reprojection.
        for row in 0..3 {
            h[row*4] *= e.transforms.output_width as f32 / e.ow as f32;
            h[row*4+1] *= e.transforms.output_height as f32 / e.oh as f32;
        }
        if h.iter().any(|v| !v.is_finite()) { return -3; }
        std::ptr::copy_nonoverlapping(h.as_ptr(),output,12);
        0
    })).unwrap_or(-4)
}

#[no_mangle]
pub unsafe extern "C" fn mc_engine_destroy(engine: *mut Engine) {
    if !engine.is_null() { drop(Box::from_raw(engine)); }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Config {
        Config {use_gpu:false,options:Options::default(),width:640,height:360,output_width:640,output_height:360,duration_ms:1000.0,fps:30.0,
            frames:(0..30).map(|i|Frame {timestamp_us:i*33333,k:[500.,0.,320.,0.,510.,180.,0.,0.,1.]}).collect(),
            gyro:(-5..110).map(|i|Gyro{timestamp_ms:i as f64*10.,gyro:[0.,0.,0.]}).collect()}
    }
    #[test]
    fn stationary_motion_and_full_intrinsics() {
        let engine = create(fixture()).unwrap();
        let params = gyroflow_core::stabilization::ComputeParams::from_manager(&engine.manager);
        let (k,_,_,_,_,_) = gyroflow_core::stabilization::FrameTransform::get_lens_data_at_timestamp(&params,500.,false);
        assert_eq!(k[(0,0)],500.); assert_eq!(k[(1,1)],510.); assert_eq!(k[(0,2)],320.);
        assert!(!engine.manager.gyro.read().quaternions.is_empty());
        assert!(engine.manager.params.read().fovs.iter().all(|v|*v > 0.9));
    }
    #[test]
    fn per_frame_intrinsics_follow_zoom() {
        let mut input = fixture();
        input.frames[15].k = [650.,0.,315.,0.,660.,185.,0.,0.,1.];
        let engine = create(input).unwrap();
        let params = gyroflow_core::stabilization::ComputeParams::from_manager(&engine.manager);
        let (early,_,_,_,_,_) = gyroflow_core::stabilization::FrameTransform::get_lens_data_at_timestamp(&params,0.,false);
        let (zoomed,_,_,_,_,_) = gyroflow_core::stabilization::FrameTransform::get_lens_data_at_timestamp(&params,499.995,false);
        assert_eq!(early[(0,0)],500.); assert_eq!(early[(0,2)],320.);
        assert_eq!(zoomed[(0,0)],650.); assert_eq!(zoomed[(1,1)],660.);
        assert_eq!(zoomed[(0,2)],315.); assert_eq!(zoomed[(1,2)],185.);
    }
    #[test]
    #[ignore = "requires a physical Metal GPU"]
    fn metal_reprojection_matches_cpu() {
        let mut cpu_config = fixture();
        cpu_config.options.allow_black_borders = true;
        cpu_config.options.max_crop = 1.;
        for sample in &mut cpu_config.gyro { sample.gyro = [0., 0., (sample.timestamp_ms / 100.).sin() * 2.]; }
        let mut gpu_config = fixture();
        gpu_config.options = cpu_config.options.clone();
        for (gpu, cpu) in gpu_config.gyro.iter_mut().zip(&cpu_config.gyro) { gpu.gyro = cpu.gyro; }
        gpu_config.use_gpu = true;
        let mut cpu = create(cpu_config).unwrap();
        let mut gpu = create(gpu_config).unwrap();
        let mut input = vec![0u8;640*360*4];
        for y in 0..360 { for x in 0..640 {
            let p = (y*640+x)*4;
            input[p..p+4].copy_from_slice(&[(x*200/640+20) as u8, (y*200/360+20) as u8, 160, 255]);
        }}
        for timestamp in [0, 200000, 500000, 800000] {
            let mut outputs = Vec::new();
            for engine in [&mut cpu, &mut gpu] {
                let start = std::time::Instant::now();
                let mut output = vec![0u8;640*360*4];
                let mut err = vec![0i8;1024];
                let status = unsafe { mc_engine_process(engine, timestamp, input.as_mut_ptr(),input.len(),2560,
                    output.as_mut_ptr(),output.len(),2560,err.as_mut_ptr(),err.len()) };
                assert_eq!(status,0, "{}", unsafe { CStr::from_ptr(err.as_ptr()) }.to_string_lossy());
                println!("gpu={} elapsed={:?}", engine.use_gpu, start.elapsed());
                assert!(output.iter().filter(|v| **v > 10).count() > output.len()/2);
                outputs.push(output);
            }
            let mae = outputs[0].iter().zip(&outputs[1]).map(|(a,b)| (*a as f64 - *b as f64).abs()).sum::<f64>() / outputs[0].len() as f64;
            println!("timestamp={timestamp} CPU/GPU mean pixel difference={mae}");
            assert!(mae < 3.0);
        }
    }
    #[test]
    fn cpu_reprojection_produces_pixels() {
        let mut e = create(fixture()).unwrap();
        let mut input = vec![0u8;640*360*4];
        for px in input.chunks_exact_mut(4) { px.copy_from_slice(&[20,80,160,255]); }
        let mut output = vec![0u8;640*360*4];
        let mut err = vec![0i8;1024];
        let status = unsafe { mc_engine_process(&mut e, 500000, input.as_mut_ptr(),input.len(),2560,
            output.as_mut_ptr(),output.len(),2560,err.as_mut_ptr(),err.len()) };
        assert_eq!(status,0);
        let center=(180*640+320)*4;
        assert_eq!(&output[center..center+4], &[20,80,160,255]);
        let invalid = unsafe { mc_engine_process(&mut e,500000,input.as_mut_ptr(),4,2560,
            output.as_mut_ptr(),output.len(),2560,err.as_mut_ptr(),err.len()) };
        assert_eq!(invalid,-1);
    }
    #[test]
    fn fixed_crop_and_black_border_limit_are_applied() {
        let mut input = fixture();
        input.options.max_crop = 5.0;
        input.options.dynamic_crop = false;
        input.options.allow_black_borders = true;
        let engine = create(input).unwrap();
        assert!(engine.manager.params.read().fovs.iter().all(|v| (*v-0.2).abs() < 1e-12));
        let mut wide = fixture();
        wide.options.max_crop = 1.0;
        wide.options.allow_black_borders = true;
        for sample in &mut wide.gyro { sample.gyro = [0., 0., (sample.timestamp_ms / 80.).sin()*3.]; }
        let engine = create(wide).unwrap();
        assert!(engine.manager.params.read().fovs.iter().all(|v| (*v-1.0).abs() < 1e-12));
    }
    #[test]
    fn stronger_smoothing_changes_motion_when_black_borders_allowed() {
        let mut weak = fixture();
        weak.options.allow_black_borders = true;
        weak.options.strength = 0.0;
        for sample in &mut weak.gyro { sample.gyro = [0., 0., (sample.timestamp_ms/100.).sin()*2.]; }
        let mut strong = fixture();
        strong.options.allow_black_borders = true;
        strong.options.strength = 1.0;
        for sample in &mut strong.gyro { sample.gyro = [0., 0., (sample.timestamp_ms/100.).sin()*2.]; }
        let a = create(weak).unwrap(); let b = create(strong).unwrap();
        let ga = a.manager.gyro.read(); let gb = b.manager.gyro.read();
        assert!(ga.smoothed_quaternions.iter().any(|(t, q)| q.angle_to(&gb.smoothed_quaternions[t]) > 0.01));
    }
    #[test]
    fn crop_multiplier_matches_pixels_at_half_resolution() {
        for (crop, expected) in [(1.0, 25i32), (5.0, 107i32)] {
            let mut config = fixture();
            config.output_width = 320; config.output_height = 180;
            config.options.dynamic_crop = false; config.options.allow_black_borders = true;
            config.options.max_crop = crop;
            let mut e = create(config).unwrap();
            let mut input = vec![0u8; 640*360*4];
            for y in 0..360 { for x in 0..640 {
                let index = (y*640+x)*4;
                input[index+2] = (x*255/639) as u8; input[index+3] = 255;
            }}
            let mut output = vec![0u8; 320*180*4]; let mut error = vec![0i8;1024];
            let status = unsafe { mc_engine_process(&mut e, 500000, input.as_mut_ptr(), input.len(),2560,
                output.as_mut_ptr(), output.len(),1280,error.as_mut_ptr(),error.len()) };
            assert_eq!(status, 0);
            let pixel = output[(90*320+32)*4+2] as i32;
            assert!((pixel-expected).abs() <= 2, "crop={crop}, pixel={pixel}, expected={expected}");
        }
    }
    #[test]
    fn allowed_borders_are_rendered_and_crop_removes_them() {
        let mut counts = Vec::new();
        for crop in [1.0, 2.0] {
            let mut config = fixture();
            config.options.allow_black_borders = true;
            config.options.dynamic_crop = false;
            config.options.max_crop = crop;
            config.options.strength = 1.0;
            for sample in &mut config.gyro {
                sample.gyro = [0., 0., (sample.timestamp_ms / 100.).sin() * 2.];
            }
            let mut e = create(config).unwrap();
            let mut input = vec![255u8; 640*360*4];
            let mut output = vec![0u8; 640*360*4];
            let mut error = vec![0i8; 1024];
            let mut black = 0;
            for timestamp in [200000, 400000, 600000, 800000] {
                let status = unsafe { mc_engine_process(&mut e, timestamp,
                    input.as_mut_ptr(), input.len(), 2560,
                    output.as_mut_ptr(), output.len(), 2560, error.as_mut_ptr(), error.len()) };
                assert_eq!(status, 0);
                black += output.chunks_exact(4).filter(|p| p[0] == 0 && p[1] == 0 && p[2] == 0).count();
            }
            counts.push(black);
        }
        println!("black pixels across four frames: 1x={}, 2x={}", counts[0], counts[1]);
        assert!(counts[0] > 1000);
        assert!(counts[1] < counts[0]);
    }
    #[test]
    fn native_transform_preserves_fov_at_half_resolution() {
        for crop in [1., 5.] {
            let mut config = fixture();
            config.output_width = 320; config.output_height = 180;
            config.options.allow_black_borders = true;
            config.options.dynamic_crop = false; config.options.max_crop = crop;
            let mut e = create(config).unwrap();
            let mut h = [0f32;12];
            assert_eq!(unsafe { mc_engine_transform(&mut e, 500000, h.as_mut_ptr(),12) },0);
            let x = 32.; let y = 90.;
            let u = (h[0]*x+h[1]*y+h[2])/(h[8]*x+h[9]*y+h[10]);
            assert!((u-(320.-256./crop as f32)).abs() < 0.01, "crop={crop}, u={u}");
        }
    }
    #[test]
    fn native_transform_preserves_fov_at_2_8k() {
        for crop in [1., 5.] {
            let mut config = fixture();
            config.width = 3840; config.height = 2160;
            config.output_width = 2816; config.output_height = 1584;
            for frame in &mut config.frames {
                for i in [0, 1, 2, 3, 4, 5] { frame.k[i] *= 6.; }
            }
            config.options.allow_black_borders = true;
            config.options.dynamic_crop = false; config.options.max_crop = crop;
            let mut engine = create(config).unwrap();
            let mut h = [0f32; 12];
            assert_eq!(unsafe { mc_engine_transform(&mut engine, 500000, h.as_mut_ptr(), 12) }, 0);
            let x = 281.6; let y = 792.;
            let u = (h[0]*x+h[1]*y+h[2])/(h[8]*x+h[9]*y+h[10]);
            assert!((u-(1920.-1536./crop as f32)).abs() < 0.01, "crop={crop}, u={u}");
        }
    }
    #[test]
    fn malformed_time_is_rejected() {
        let mut input=fixture(); input.gyro[2].timestamp_ms=input.gyro[1].timestamp_ms;
        assert!(create(input).is_err());
    }
}
