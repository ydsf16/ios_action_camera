#!/usr/bin/env python3
"""Generate the Xcode project; build the pinned Rust library with build_engine.sh first."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value):
    return json.dumps(value)
objects = []
def obj(name, content):
    objects.append(f'{uid(name)} = {{ {content} }};')
    return uid(name)
files = sorted(list(root.glob('App/**/*.swift')) + list(root.glob('Sources/CaptureCore/*.swift')))
refs, builds = [], []
for file in files:
    path = str(file.relative_to(root))
    ref = obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    build = obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref};')
    refs.append(ref); builds.append(build)
resources = []
for path in ['LICENSE', 'THIRD_PARTY_NOTICES.md']:
    ref = obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = text; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    resources.append(obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref};'))
app = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = MotionCam.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
obj('group', f'isa = PBXGroup; children = ({",".join(refs + [uid("products")])},); sourceTree = "<group>";')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)},); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug', 'Release']:
    common = {'SDKROOT':'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'CLANG_ENABLE_MODULES':'YES',
              'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'targeted', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
    if mode == 'Debug':
        common.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ENABLE_TESTABILITY='YES', DEBUG_INFORMATION_FORMAT='dwarf')
    else:
        common.update(SWIFT_OPTIMIZATION_LEVEL='-O', SWIFT_COMPILATION_MODE='wholemodule', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym')
    appsettings = {'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.grape.MotionCam',
        'INFOPLIST_FILE':'App/Resources/Info.plist', 'GENERATE_INFOPLIST_FILE':'NO', 'TARGETED_DEVICE_FAMILY':'1',
        'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO',
        'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO', 'MARKETING_VERSION':'0.3.0', 'CURRENT_PROJECT_VERSION':'6',
        'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'F2LVFHW3ZH',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
        'ARCHS':'arm64',
        'SWIFT_OBJC_BRIDGING_HEADER':'App/MotionCam-Bridging-Header.h',
        'HEADER_SEARCH_PATHS':'$(inherited) $(SRCROOT)/Engine/include',
        'GYROFLOW_STATIC_LIBRARY[sdk=iphoneos*]':'$(SRCROOT)/Engine/target/aarch64-apple-ios/release/libmotioncam_gyroflow.a',
        'GYROFLOW_STATIC_LIBRARY[sdk=iphonesimulator*]':'$(SRCROOT)/Engine/target/aarch64-apple-ios-sim/release/libmotioncam_gyroflow.a',
        'OTHER_LDFLAGS':'$(inherited) "$(GYROFLOW_STATIC_LIBRARY)" -lc++ -liconv -framework Metal -framework QuartzCore -framework Security -framework SystemConfiguration'}
    for group, settings in [('project', common), ('app', appsettings)]:
        fields = ' '.join(f'{q(k)} = {q(v)};' for k,v in settings.items())
        obj(group+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {fields} }}; name = {mode};')
for group in ['project','app']:
    obj(group+'configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(group+"Debug")},{uid(group+"Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("appconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")},); buildRules = (); dependencies = (); name = MotionCam; productName = MotionCam; productReference = {app}; productType = "com.apple.product-type.application";')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base, "zh-Hans",); mainGroup = {uid("group")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},);')
project = root / 'MotionCam.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="MotionCam.app" BlueprintName="MotionCam" ReferencedContainer="container:MotionCam.xcodeproj"/>'
(scheme/'MotionCam.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated {project.name}: {len(files)} Swift files')
