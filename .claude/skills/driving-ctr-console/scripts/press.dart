/// Presses console buttons through Luma3DS Rosalina InputRedirection (UDP 4950).
///
/// Usage: dart press.dart <ip> <button> [<button> ...]   (each pressed then
/// released)
///
/// Packet: 5 little-endian u32s: pad (0xfff XOR pressed bits), touch, circle
/// pad, c-stick/ZL/ZR, interface buttons (HOME=1, POWER=2).
library;

import 'dart:io';
import 'dart:typed_data';

const inputRedirectionPort = 4950;

const padBits = {
  'A': 0,
  'B': 1,
  'SELECT': 2,
  'START': 3,
  'RIGHT': 4,
  'LEFT': 5,
  'UP': 6,
  'DOWN': 7,
  'R': 8,
  'L': 9,
  'X': 10,
  'Y': 11,
};
const homeInterfaceBit = 1;

const idlePad = 0xFFF;
const idleTouch = 0x2000000;
const idleCirclePad = 0x7FF7FF;
const idleCStick = 0x80800081;

/// Packets per press and per release; UDP may drop one.
const pressPackets = 6;
const releasePackets = 4;
const packetInterval = Duration(milliseconds: 25);

/// Pause after each button so the console handles one press at a time.
const buttonInterval = Duration(milliseconds: 600);

Uint8List packet({int padPressed = 0, int interface = 0}) {
  final data = ByteData(20)
    ..setUint32(0, idlePad ^ padPressed, Endian.little)
    ..setUint32(4, idleTouch, Endian.little)
    ..setUint32(8, idleCirclePad, Endian.little)
    ..setUint32(12, idleCStick, Endian.little)
    ..setUint32(16, interface, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List pressedPacket(String button) => button == 'HOME'
    ? packet(interface: homeInterfaceBit)
    : packet(padPressed: 1 << padBits[button]!);

Future<void> main(List<String> arguments) async {
  final buttons = [for (final b in arguments.skip(1)) b.toUpperCase()];
  final unknown = buttons.where((b) => b != 'HOME' && !padBits.containsKey(b));
  if (arguments.length < 2 || unknown.isNotEmpty) {
    stderr.writeln(
      'usage: dart press.dart <ip> <button> [<button> ...]\n'
      'buttons: ${[...padBits.keys, 'HOME'].join(' ')}',
    );
    exitCode = 64;
    return;
  }
  final target = InternetAddress(arguments[0]);
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    Future<void> send(Uint8List data, int count) async {
      for (var i = 0; i < count; i++) {
        if (socket.send(data, target, inputRedirectionPort) != data.length) {
          throw SocketException('UDP send to ${target.address} failed');
        }
        await Future<void>.delayed(packetInterval);
      }
    }

    for (final button in buttons) {
      await send(pressedPacket(button), pressPackets);
      await send(packet(), releasePackets);
      stdout.writeln('pressed $button');
      await Future<void>.delayed(buttonInterval);
    }
  } finally {
    socket.close();
  }
}
