import os, uuid

def gen_id():
    return uuid.uuid4().hex[:24].upper()

proj_id = gen_id()
target_id = gen_id()
config_list_proj_id = gen_id()
config_list_target_id = gen_id()
debug_proj_id = gen_id()
release_proj_id = gen_id()
debug_target_id = gen_id()
release_target_id = gen_id()
group_main_id = gen_id()
group_sources_id = gen_id()
group_products_id = gen_id()
sources_build_phase_id = gen_id()
frameworks_build_phase_id = gen_id()
resources_build_phase_id = gen_id()
protobuf_pkg_id = gen_id()
protobuf_product_id = gen_id()
protobuf_build_file_id = gen_id()
app_ref_id = gen_id()

swift_files = []
for root, dirs, files in os.walk("StockDeck"):
    for file in files:
        if file.endswith(".swift"):
            swift_files.append(os.path.join(root, file))

file_refs_str = []
build_files_str = []
group_children_str = []
sources_phase_str = []

for path in sorted(swift_files):
    f_id = gen_id()
    b_id = gen_id()
    fname = os.path.basename(path)
    file_refs_str.append(f'\t\t{f_id} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = "<group>"; }};')
    build_files_str.append(f'\t\t{b_id} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {f_id}; }};')
    group_children_str.append(f'\t\t\t\t{f_id} /* {fname} */,')
    sources_phase_str.append(f'\t\t\t\t{b_id} /* {fname} in Sources */,')

font_ref_id = gen_id()
font_build_id = gen_id()
file_refs_str.append(f'\t\t{font_ref_id} /* InterVariable.ttf */ = {{isa = PBXFileReference; lastKnownFileType = file; path = "StockDeck/Fonts/InterVariable.ttf"; sourceTree = "<group>"; }};')
group_children_str.append(f'\t\t\t\t{font_ref_id} /* InterVariable.ttf */,')

pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 54;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files_str)}
		{font_build_id} /* InterVariable.ttf in Resources */ = {{isa = PBXBuildFile; fileRef = {font_ref_id}; }};
		{protobuf_build_file_id} /* SwiftProtobuf in Frameworks */ = {{isa = PBXBuildFile; productRef = {protobuf_product_id}; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{chr(10).join(file_refs_str)}
		{app_ref_id} /* StockDeck.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = StockDeck.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{frameworks_build_phase_id} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{protobuf_build_file_id} /* SwiftProtobuf in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{group_main_id} = {{
			isa = PBXGroup;
			children = (
				{group_sources_id} /* StockDeck */,
				{group_products_id} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{group_sources_id} /* StockDeck */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(group_children_str)}
			);
			name = StockDeck;
			sourceTree = "<group>";
		}};
		{group_products_id} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{app_ref_id} /* StockDeck.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{target_id} /* StockDeck */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {config_list_target_id} /* Build configuration list for PBXNativeTarget "StockDeck" */;
			buildPhases = (
				{sources_build_phase_id} /* Sources */,
				{frameworks_build_phase_id} /* Frameworks */,
				{resources_build_phase_id} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = StockDeck;
			packageProductDependencies = (
				{protobuf_product_id} /* SwiftProtobuf */,
			);
			productName = StockDeck;
			productReference = {app_ref_id} /* StockDeck.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{proj_id} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{target_id} = {{
						CreatedOnToolsVersion = 15.0;
						ProvisioningStyle = Automatic;
					}};
				}};
			}};
			buildConfigurationList = {config_list_proj_id} /* Build configuration list for PBXProject "StockDeck" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {group_main_id};
			packageReferences = (
				{protobuf_pkg_id} /* XCRemoteSwiftPackageReference "swift-protobuf" */,
			);
			productRefGroup = {group_products_id} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target_id} /* StockDeck */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_build_phase_id} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{font_build_id} /* InterVariable.ttf in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_build_phase_id} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(sources_phase_str)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCRemoteSwiftPackageReference section */
		{protobuf_pkg_id} /* XCRemoteSwiftPackageReference "swift-protobuf" */ = {{
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/apple/swift-protobuf.git";
			requirement = {{
				kind = versionRequirement;
				minimumVersion = 1.28.0;
			}};
		}};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{protobuf_product_id} /* SwiftProtobuf */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {protobuf_pkg_id} /* XCRemoteSwiftPackageReference "swift-protobuf" */;
			productName = SwiftProtobuf;
		}};
/* End XCSwiftPackageProductDependency section */

/* Begin XCBuildConfiguration section */
		{debug_proj_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_STRICT_OBJC_PROTOMSGS = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = StockDeck;
				INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.terry.stockdeck.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{release_proj_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_STRICT_OBJC_PROTOMSGS = YES;
				GCC_C_LANGUAGE_STANDARD = gnu11;
				GCC_NO_COMMON_BLOCKS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = StockDeck;
				INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.terry.stockdeck.ios;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
		{debug_target_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = StockDeck;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.terry.stockdeck.ios;
				PRODUCT_NAME = StockDeck;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Debug;
		}};
		{release_target_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = StockDeck;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.terry.stockdeck.ios;
				PRODUCT_NAME = StockDeck;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = "1,2";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{config_list_proj_id} /* Build configuration list for PBXProject "StockDeck" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{debug_proj_id} /* Debug */,
				{release_proj_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{config_list_target_id} /* Build configuration list for PBXNativeTarget "StockDeck" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{debug_target_id} /* Debug */,
				{release_target_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {proj_id} /* Project object */;
}}
"""

os.makedirs("StockDeckApp.xcodeproj", exist_ok=True)
with open("StockDeckApp.xcodeproj/project.pbxproj", "w") as f:
    f.write(pbxproj)
print("Created StockDeckApp.xcodeproj successfully!")
