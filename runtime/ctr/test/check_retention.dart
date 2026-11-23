import 'dart:io';

import '../../../toolchain/native_kernel.dart' show verifyRetainedHooks;

void main(List<String> args) {
  verifyRetainedHooks(File(args.single));
  print('Private hooks retained in CTR kernel');
}
