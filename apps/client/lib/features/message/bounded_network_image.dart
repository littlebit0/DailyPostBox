import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

const maxRemoteImageBytes = 5 * 1024 * 1024;
const remoteImageTimeout = Duration(seconds: 15);

/// Downloads [uri] (http/https only) and throws once the body is over
/// [maxBytes] or the whole request outlives [timeout].
Future<Uint8List> fetchBoundedImage(
  Uri uri, {
  int maxBytes = maxRemoteImageBytes,
  Duration timeout = remoteImageTimeout,
}) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ArgumentError('Unsupported image scheme: ${uri.scheme}');
  }
  final client = HttpClient();
  try {
    return await () async {
      final response = await (await client.getUrl(uri)).close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Image request failed', uri: uri);
      }
      if (response.contentLength > maxBytes) {
        throw HttpException('Image too large', uri: uri);
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response) {
        out.add(chunk);
        if (out.length > maxBytes) {
          throw HttpException('Image too large', uri: uri);
        }
      }
      return out.takeBytes();
    }()
        .timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

/// NetworkImage replacement with a download size and time limit.
@immutable
class BoundedNetworkImage extends ImageProvider<BoundedNetworkImage> {
  const BoundedNetworkImage(this.url);

  final String url;

  @override
  Future<BoundedNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    BoundedNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: () async {
        final bytes = await fetchBoundedImage(Uri.parse(key.url));
        return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      }(),
      scale: 1.0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BoundedNetworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
