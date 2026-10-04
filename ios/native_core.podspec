#
# Local pod that compiles the Maxima C++23 security core directly into
# the iOS Runner binary. Symbols are looked up by Dart FFI through
# DynamicLibrary.process(), so the target must keep them exported:
# the -export_dynamic flag below does that.
#
Pod::Spec.new do |s|
  s.name             = 'native_core'
  s.version          = '6.0.0'
  s.summary          = 'Maxima native security core (memory purge, voice print, SIP bridge)'
  s.homepage         = 'https://example.invalid/maxima'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Maxima' => 'noreply@example.invalid' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.source_files     = '../src/native_core.cpp', '../src/sip_bridge.cpp'
  s.library          = 'c++'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++23',
    'GCC_SYMBOLS_PRIVATE_EXTERN'  => 'NO',
  }
  # Exported dynamically so DynamicLibrary.process() resolves the
  # maxima_* symbols; -ObjC/-all_load prevent dead-stripping of the
  # unreferenced C entry points in the static archive.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC -Wl,-export_dynamic',
    'DEAD_CODE_STRIPPING' => 'NO',
  }
end
