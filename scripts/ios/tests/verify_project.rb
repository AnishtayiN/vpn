require 'xcodeproj'
root = File.expand_path('../../..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'ios/Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
extension = project.targets.find { |t| t.name == 'PacketTunnel' }
raise 'Missing extension dependency' unless runner.dependencies.any? { |d| d.target == extension }
raise 'Missing embedded extension' unless runner.copy_files_build_phases.any? { |p| p.files_references.include?(extension.product_reference) }
[runner, extension].each do |target|
  target.source_build_phase.files_references.each do |ref|
    raise "Missing source #{ref.real_path}" unless ref.real_path.file?
  end
end
extension.build_configurations.each do |config|
  ref = config.base_configuration_reference
  raise "Wrong extension configuration path: #{ref&.real_path}" unless ref && ref.real_path.file? && ref.real_path.basename.to_s == 'Generated.xcconfig'
  raise 'Extension must not link Flutter' if config.build_settings.fetch('OTHER_LDFLAGS').join(' ').include?('-framework Flutter')
  raise 'Missing entitlement' unless config.build_settings['CODE_SIGN_ENTITLEMENTS'] == 'PacketTunnel/PacketTunnel.entitlements'
  raise 'Extension must not be installed standalone' unless config.build_settings['SKIP_INSTALL'] == 'YES'
end
puts 'Generated Xcode app + extension structure verified'
