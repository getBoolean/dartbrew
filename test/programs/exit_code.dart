// exit(n) ends the program at once (U8). The run is expected to fail with
// exit code 3: `dartbrew run --verdict` exits 3, and the journal's terminal
// record carries "outcome":"fail" and "exit_code":3 after a passing cleanup.
import 'dart:async';
import 'dart:io';

void main() {
  // Neither the pending timer nor the finally block runs after exit.
  Timer(const Duration(milliseconds: 50), () => print('timer:ran'));
  print('exit:3');
  // A partial stdout line still reaches the output before the end.
  stdout.write('partial line');
  try {
    exit(3);
  } finally {
    print('finally:ran');
  }
}
