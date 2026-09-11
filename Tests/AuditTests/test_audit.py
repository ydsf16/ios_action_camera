import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('audit', Path(__file__).resolve().parents[2] / 'scripts/audit_recording.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        manifest = dict(id='test', status='complete', videoFrames=2,
                        firstVideoPTS=dict(value=100000, timescale=1000), firstVideoHostSeconds=200,
                        gyroSamples=3, accelerometerSamples=3, gravitySamples=3,
                        audioBuffers=1, droppedVideoFrames=0)
        (self.root / 'manifest.json').write_text(json.dumps(manifest))
        k = ','.join(f'k{r}{c}' for r in range(3) for c in range(3))
        (self.root / 'frames.csv').write_text(f'pts_value,pts_timescale,host_sec,video_sec,{k},stabilization_active\n'
            '100000,1000,200,0,1000,0,960,0,1000,540,0,0,1,0\n'
            '100033,1000,200.033,0.033,1000,0,960,0,1000,540,0,0,1,0\n')
        for name in ['gyro','accelerometer','gravity']:
            (self.root / (name+'.csv')).write_text('host_sec,x,y,z\n199.99,0,0,1\n200.01,0,0,1\n200.04,0,0,1\n')
        (self.root / 'audio.csv').write_text('pts_value,pts_timescale,video_sec\n100010,1000,0.01\n')
        (self.root / 'drops.csv').write_text('stream,pts_value,pts_timescale,reason\n')
        (self.root / 'video.mov').touch()  # No ffprobe in fixture tests.

    def test_valid_shared_origin(self):
        report = module.audit(self.root, probe=False)
        self.assertEqual(report['errors'], [])
        self.assertAlmostEqual(report['recorded_host_to_video_rate_ppm'], 0, places=4)

    def test_detects_independently_zeroed_imu(self):
        (self.root / 'gyro.csv').write_text('host_sec,x,y,z\n0,0,0,1\n0.01,0,0,1\n0.02,0,0,1\n')
        self.assertIn('gyro: does not cover first/last video frame', module.audit(self.root, probe=False)['errors'])

    def test_detects_audio_origin_error(self):
        (self.root / 'audio.csv').write_text('pts_value,pts_timescale,video_sec\n100010,1000,0\n')
        self.assertIn('Audio uses a different origin from video', module.audit(self.root, probe=False)['errors'])


if __name__ == '__main__':
    unittest.main()
