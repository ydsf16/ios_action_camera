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
files = sorted(list(root.glob('App/**/*.swift')) + list(root.glob('App/**/*.metal')) + list(root.glob('Sources/CaptureCore/*.swift')))
refs, builds = [], []
for file in files:
    path = str(file.relative_to(root))
    kind = 'sourcecode.metal' if file.suffix == '.metal' else 'sourcecode.swift'
    ref = obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    build = obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref};')
    refs.append(ref); builds.append(build)
resources = []
for path in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_LICENSES.txt', 'App/Resources/PrivacyInfo.xcprivacy']:
    ref = obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = text; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    resources.append(obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref};'))
for catalog in sorted(root.glob('App/**/*.xcassets')):
    path = str(catalog.relative_to(root))
    ref = obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    resources.append(obj('build:'+path, f'isa = PBXBuildFile; fileRef = {ref};'))
testrefs, testbuilds = [], []
for path in ['AppTests/CommerceTests.swift', 'AppTests/RoamShot.storekit']:
    kind = 'sourcecode.swift' if path.endswith('.swift') else 'text'
    testrefs.append(obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;'))
    testbuilds.append(obj('build:'+path, f'isa = PBXBuildFile; fileRef = {testrefs[-1]};'))
refs += testrefs
testproduct = obj('testproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CommerceTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
app = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = RoamShot.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; children = ({app},{testproduct},); name = Products; sourceTree = "<group>";')
obj('group', f'isa = PBXGroup; children = ({",".join(refs + [uid("products")])},); sourceTree = "<group>";')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resources)},); runOnlyForDeploymentPostprocessing = 0;')
obj('testSources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuilds[0]},); runOnlyForDeploymentPostprocessing = 0;')
obj('testResources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuilds[1]},); runOnlyForDeploymentPostprocessing = 0;')
obj('testFrameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug', 'Release']:
    common = {'SDKROOT':'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'CLANG_ENABLE_MODULES':'YES',
              'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'targeted', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
    if mode == 'Debug':
        common.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ENABLE_TESTABILITY='YES', DEBUG_INFORMATION_FORMAT='dwarf')
    else:
        common.update(SWIFT_OPTIMIZATION_LEVEL='-O', SWIFT_COMPILATION_MODE='wholemodule', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym')
    appsettings = {'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.grape.RoamShot',
        'INFOPLIST_FILE':'App/Resources/Info.plist', 'GENERATE_INFOPLIST_FILE':'NO', 'TARGETED_DEVICE_FAMILY':'1',
        'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO',
        'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO', 'MARKETING_VERSION':'1.0.0', 'CURRENT_PROJECT_VERSION':'26',
        'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
        'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'F2LVFHW3ZH',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
        'ARCHS':'arm64',
        'SWIFT_OBJC_BRIDGING_HEADER':'App/RoamShot-Bridging-Header.h',
        'HEADER_SEARCH_PATHS':'$(inherited) $(SRCROOT)/Engine/include',
        'GYROFLOW_STATIC_LIBRARY[sdk=iphoneos*]':'$(SRCROOT)/Engine/target/aarch64-apple-ios/release/libroamshot_gyroflow.a',
        'GYROFLOW_STATIC_LIBRARY[sdk=iphonesimulator*]':'$(SRCROOT)/Engine/target/aarch64-apple-ios-sim/release/libroamshot_gyroflow.a',
        'OTHER_LDFLAGS':'$(inherited) "$(GYROFLOW_STATIC_LIBRARY)" -lc++ -liconv -framework Metal -framework QuartzCore -framework Security -framework SystemConfiguration'}
    testsettings = {'HEADER_SEARCH_PATHS':'$(inherited) $(SRCROOT)/Engine/include', 'PRODUCT_NAME':'CommerceTests', 'PRODUCT_BUNDLE_IDENTIFIER':'com.grape.RoamShot.CommerceTests',
        'GENERATE_INFOPLIST_FILE':'YES', 'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/RoamShot.app/RoamShot',
        'BUNDLE_LOADER':'$(TEST_HOST)', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'F2LVFHW3ZH',
        'SWIFT_VERSION':'5.0', 'TARGETED_DEVICE_FAMILY':'1', 'ARCHS':'arm64',
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'}
    for group, settings in [('project', common), ('app', appsettings), ('test', testsettings)]:
        fields = ' '.join(f'{q(k)} = {q(v)};' for k,v in settings.items())
        obj(group+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {fields} }}; name = {mode};')
for group in ['project','app','test']:
    obj(group+'configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(group+"Debug")},{uid(group+"Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("appconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")},); buildRules = (); dependencies = (); name = RoamShot; productName = RoamShot; productReference = {app}; productType = "com.apple.product-type.application";')
obj('testProxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = RoamShot;')
obj('testDependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("testProxy")};')
obj('testTarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("testconfigs")}; buildPhases = ({uid("testSources")},{uid("testFrameworks")},{uid("testResources")},); buildRules = (); dependencies = ({uid("testDependency")},); name = CommerceTests; productName = CommerceTests; productReference = {testproduct}; productType = "com.apple.product-type.bundle.unit-test";')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base, "zh-Hans",); mainGroup = {uid("group")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},{uid("testTarget")},);')
project = root / 'RoamShot.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="RoamShot.app" BlueprintName="RoamShot" ReferencedContainer="container:RoamShot.xcodeproj"/>'
(scheme/'RoamShot.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated {project.name}: {len(files)} source files')

testref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("testTarget")}" BuildableName="CommerceTests.xctest" BlueprintName="CommerceTests" ReferencedContainer="container:RoamShot.xcodeproj"/>'
(scheme/'CommerceQA.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{testref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO" parallelizable="NO">{testref}</TestableReference></Testables><CommandLineArguments><CommandLineArgument argument="--commerce-tests" isEnabled="YES"/></CommandLineArguments></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable><CommandLineArguments><CommandLineArgument argument="--upgrade" isEnabled="YES"/></CommandLineArguments><StoreKitConfigurationFileReference identifier="../../AppTests/RoamShot.storekit"/></LaunchAction>
</Scheme>''')
