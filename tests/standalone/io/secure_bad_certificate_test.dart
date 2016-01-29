// Copyright (c) 2013, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This test verifies that the bad certificate callback works.

import "dart:async";
import "dart:io";

import "package:expect/expect.dart";

final HOST_NAME = 'localhost';

String localFile(path) => Platform.script.resolve(path).toFilePath();
List<int> readLocalFile(path) => (new File(localFile(path))).readAsBytesSync();

SecurityContext serverContext = new SecurityContext()
  ..useCertificateChain(localFile('certificates/server_chain.pem'))
  ..usePrivateKeyAsBytes(readLocalFile('certificates/server_key.pem'),
                         password: 'dartdart');

class CustomException {}

main() async {
  var HOST = (await InternetAddress.lookup(HOST_NAME)).first;
  var server = await SecureServerSocket.bind(HOST_NAME, 0, serverContext);
  server.listen((SecureSocket socket) {
      socket.listen((_) {}, onDone: () {
        socket.close();
      });
    }, onError: (e) { if (e is! HandshakeException) throw e; });

  SecurityContext goodContext = new SecurityContext()
    ..setTrustedCertificates(file: localFile('certificates/trusted_certs.pem'));
  SecurityContext badContext = new SecurityContext();
  SecurityContext defaultContext = SecurityContext.defaultContext;

  await runClient(server.port, goodContext, true, 'pass');
  await runClient(server.port, goodContext, false, 'pass');
  await runClient(server.port, goodContext, 'fisk', 'pass');
  await runClient(server.port, goodContext, 'exception', 'pass');
  await runClient(server.port, badContext, true, 'pass');
  await runClient(server.port, badContext, false, 'fail');
  await runClient(server.port, badContext, 'fisk', 'fail');
  await runClient(server.port, badContext, 'exception', 'throw');
  await runClient(server.port, defaultContext, true, 'pass');
  await runClient(server.port, defaultContext, false, 'fail');
  await runClient(server.port, defaultContext, 'fisk', 'fail');
  await runClient(server.port, defaultContext, 'exception', 'throw');
  server.close();
}


Future runClient(int port,
                 SecurityContext context,
                 callbackReturns,
                 result) async {
  badCertificateCallback(X509Certificate certificate) {
    Expect.equals('/CN=rootauthority', certificate.subject);
    Expect.equals('/CN=rootauthority', certificate.issuer);
    // Throw exception if one is requested.
    if (callbackReturns == 'exception') throw new CustomException();
    return callbackReturns;
  }

  try {
    var socket = await SecureSocket.connect(
        HOST_NAME,
        port,
        context: context,
        onBadCertificate: badCertificateCallback);
    Expect.equals('pass', result);  // Is rethrown below
    await socket.close();
  } catch (error)  {
    if (error is ExpectException) rethrow;
    Expect.notEquals(result, 'pass');
    if (result == 'fail') {
      Expect.isTrue(error is HandshakeException || error is ArgumentError);
    } else if (result == 'throw') {
      Expect.isTrue(error is CustomException);
    } else {
      Expect.fail('Unknown expectation $result');
    }
  }
}
