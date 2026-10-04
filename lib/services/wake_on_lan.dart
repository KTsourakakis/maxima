import 'dart:io';

class WakeOnLan {
    const WakeOnLan({
        this.broadcastAddress = '255.255.255.255',
        this.port = 9,
    });

    final String broadcastAddress;
    final int port;

    Future<void> send(String macAddress) async {
        final macBytes = _parseMacAddress(macAddress);
        final packet = List<int>.filled(6 + (16 * 6), 0xff);

        for (var repetition = 0; repetition < 16; ++repetition) {
            final offset = 6 + repetition * 6;
            packet.setRange(offset, offset + 6, macBytes);
        }

        final socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            0,
        );
        try {
            socket.broadcastEnabled = true;
            socket.send(
                packet,
                InternetAddress(broadcastAddress),
                port,
            );
        } finally {
            socket.close();
        }
    }

    List<int> _parseMacAddress(String macAddress) {
        final normalized = macAddress.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
        if (normalized.length != 12) {
            throw ArgumentError.value(
                macAddress,
                'macAddress',
                'Expected a 48-bit MAC address',
            );
        }

        return List<int>.generate(
            6,
            (index) => int.parse(
                normalized.substring(index * 2, index * 2 + 2),
                radix: 16,
            ),
        );
    }
}
