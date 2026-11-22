/// A pin table with the fields build identity and the toolchain check read.
Map<String, Object?> sampleManifest() => {
  'schema_version': 1,
  'dart': {'version': 'fixture', 'revision': '0' * 40},
  'patches': [
    {'path': 'patches/dart/0001-fixture.patch', 'sha256': 'a' * 64},
  ],
  'dependencies': {
    'depot_tools': {'revision': '1' * 40},
  },
  'container': {'devkitARM': 'r68-1', 'gcc': '16.1.0', 'libctru': '2.7.0-1'},
};

/// A CTR target profile naming one specs file, `ctr.specs`.
Map<String, Object?> sampleProfile() => {
  'name': 'ctr-armv6k',
  'target_os': 'ctr',
  'target_cpu': 'arm',
  'arm_version': 6,
  'arm_fpu': 'vfp',
  'arm_float_abi': 'hard',
  'arm_use_neon': false,
  'arm_use_integer_division': false,
  'cflags': ['-marm', '-march=armv6k', '-mfpu=vfp', '-mfloat-abi=hard'],
  'compiler_prefix': '/opt/devkitpro/devkitARM/bin/arm-none-eabi-',
  'libctru': '/opt/devkitpro/libctru',
  'link_specs': ['ctr.specs'],
};
