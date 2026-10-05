#!/usr/bin/env ruby
# Applied after flutter create; no hand-maintained Flutter pbxproj required.
require 'xcodeproj'
require 'fileutils'
require 'json'
root = File.expand_path('../..', __dir__)
ios = File.join(root, 'ios')
bundle = ENV.fetch('IOS_BUNDLE_ID', 'pm.dnschanger.voidrauvpn')
abort 'Invalid IOS_BUNDLE_ID' unless bundle.match?(/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/)
project = Xcodeproj::Project.open(File.join(ios, 'Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
abort 'Flutter Runner target missing' unless runner
extension = project.targets.find { |t| t.name == 'PacketTunnel' }
extension ||= project.new_target(:app_extension, 'PacketTunnel', :ios, '16.0')

def add_sources(project, target, dir, paths)
  group = project.main_group.find_subpath(dir, true)
  group.set_source_tree('<group>')
  group.set_path(dir)
  paths.each do |path|
    ref = group.files.find { |f| f.path == path } || group.new_file(path)
    target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
  end
end
add_sources(project, runner, 'Runner', ['VPNPlugin.swift'])
add_sources(project, runner, 'Shared', ['TunnelConfiguration.swift'])
add_sources(project, extension, 'Shared', ['TunnelConfiguration.swift'])
add_sources(project, extension, 'PacketTunnel', %w[PacketTunnelProvider.swift PacketPump.swift TunnelProbe.swift])
runner.add_dependency(extension) unless runner.dependencies.any? { |d| d.target == extension }
embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed App Extensions' }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
unless embed.files_references.include?(extension.product_reference)
  file = embed.add_file_reference(extension.product_reference)
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
# Embed extension before Flutter's Thin Binary step to avoid Xcode cycles.
runner.build_phases.delete(embed)
runner.build_phases.insert(0, embed)

[runner, extension].each do |target|
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    settings['SWIFT_VERSION'] = '5.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = target == runner ? bundle : "#{bundle}.PacketTunnel"
    settings['PRODUCT_NAME'] = target.name
    settings['PRODUCT_MODULE_NAME'] = target.name
    settings['WRAPPER_EXTENSION'] = target == runner ? 'app' : 'appex'
    settings['CODE_SIGN_ENTITLEMENTS'] = "#{target.name}/#{target.name}.entitlements"
    settings['ENABLE_BITCODE'] = 'NO'
    settings['DEVELOPMENT_TEAM'] = ENV.fetch('APPLE_TEAM_ID', '')
    # Manual signing, configured independently for app and extension.
    if ENV['IOS_SIGNING_DIR']
      info = JSON.parse(File.read(File.join(ENV['IOS_SIGNING_DIR'], 'profiles.json')))
      settings['CODE_SIGN_STYLE'] = 'Manual'
      settings['CODE_SIGN_IDENTITY'] = 'Apple Distribution'
      settings['PROVISIONING_PROFILE_SPECIFIER'] = info.fetch(target.name).fetch('uuid')
    end
  end
end
# Do NOT inherit Runner's Release.xcconfig (it includes Pods-Runner and would
# link Flutter/UI plugins into the memory-constrained, extension-safe process).
flutter_group = project.main_group.find_subpath('Flutter', true)
generated = flutter_group.files.find { |f| File.basename(f.path.to_s) == 'Generated.xcconfig' } || flutter_group.new_file('Flutter/Generated.xcconfig')
extension.build_configurations.each do |config|
  config.base_configuration_reference = generated
  s = config.build_settings
  s['INFOPLIST_FILE'] = 'PacketTunnel/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['SWIFT_OBJC_BRIDGING_HEADER'] = 'PacketTunnel/NativeBridge.h'
  s['LIBRARY_SEARCH_PATHS'] = ['$(inherited)', '$(PROJECT_DIR)/Native']
  s['OTHER_LDFLAGS'] = ['$(inherited)', '-lvoidrau_ios_core', '-lhev-socks5-tunnel',
                       '-lc++', '-liconv', '-lresolv', '-framework', 'Security',
                       '-framework', 'SystemConfiguration', '-framework', 'NetworkExtension']
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end
# App privacy manifest. Extension has the same local-file/defaults uses.
[runner, extension].each do |target|
  group = project.main_group.find_subpath('Runner', true)
  ref = group.files.find { |f| f.path == 'PrivacyInfo.xcprivacy' } || group.new_file('PrivacyInfo.xcprivacy')
  target.resources_build_phase.add_file_reference(ref) unless target.resources_build_phase.files_references.include?(ref)
end
plist_path = File.join(ios, 'Runner/Info.plist')
plist = Xcodeproj::Plist.read_from_path(plist_path)
plist['CFBundleDisplayName'] = 'VoidrauVPN'
plist['LSApplicationQueriesSchemes'] = ['tg']
# Do not assert encryption exemption: developer must answer Apple's export
# questionnaire for this VPN's cryptography in App Store Connect.
# Only local SOCKS connectivity; no broad ATS bypass. HTTP probes use Dart sockets.
plist['NSAppTransportSecurity'] = { 'NSAllowsLocalNetworking' => true }
Xcodeproj::Plist.write_to_path(plist, plist_path)
project.save
puts "Configured #{bundle} + #{bundle}.PacketTunnel"
