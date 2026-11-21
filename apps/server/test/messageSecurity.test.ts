import assert from "node:assert/strict";
import test from "node:test";
import { detectMessageSecurity } from "../src/mail/messageSecurity.js";

const text = { type: "text/plain" };

test("plain message has no security", () => {
  assert.deepEqual(detectMessageSecurity({ type: "multipart/alternative", childNodes: [text] }), {
    signed: null, encrypted: null, verified: false
  });
});

test("detects S/MIME and OpenPGP detached signatures", () => {
  const smime = detectMessageSecurity({
    type: "multipart/signed",
    parameters: { protocol: "application/pkcs7-signature" },
    childNodes: [text, { type: "application/pkcs7-signature" }]
  });
  assert.equal(smime.signed, "smime");
  const pgp = detectMessageSecurity({
    type: "multipart/signed",
    parameters: { protocol: "application/pgp-signature" },
    childNodes: [text, { type: "application/pgp-signature" }]
  });
  assert.equal(pgp.signed, "openpgp");
  assert.equal(pgp.verified, false);
});

test("detects opaque S/MIME signed and encrypted parts", () => {
  assert.equal(
    detectMessageSecurity({ type: "application/pkcs7-mime", parameters: { "smime-type": "signed-data" } }).signed,
    "smime"
  );
  const enveloped = detectMessageSecurity({
    type: "application/pkcs7-mime",
    parameters: { "smime-type": "enveloped-data" }
  });
  assert.equal(enveloped.encrypted, "smime");
  assert.equal(enveloped.signed, null);
});

test("detects OpenPGP encrypted and nested signed", () => {
  const enc = detectMessageSecurity({
    type: "multipart/encrypted",
    parameters: { protocol: "application/pgp-encrypted" },
    childNodes: [{ type: "application/pgp-encrypted" }, { type: "application/octet-stream" }]
  });
  assert.equal(enc.encrypted, "openpgp");
  const nested = detectMessageSecurity({
    type: "multipart/mixed",
    childNodes: [{ type: "multipart/signed", parameters: { protocol: "application/pgp-signature" } }]
  });
  assert.equal(nested.signed, "openpgp");
});

test("ignores security of attached parts", () => {
  const mixed = detectMessageSecurity({
    type: "multipart/mixed",
    childNodes: [
      text,
      { type: "application/pkcs7-mime", parameters: { "smime-type": "signed-data" }, disposition: "attachment" },
      { type: "application/pkcs7-mime", parameters: { "smime-type": "enveloped-data" }, disposition: "ATTACHMENT" },
      { type: "application/pkcs7-signature", disposition: "attachment", dispositionParameters: { filename: "smime.p7s" } },
      { type: "application/pgp-signature", disposition: "attachment", dispositionParameters: { filename: "sig.asc" } },
      {
        type: "message/rfc822",
        disposition: "attachment",
        childNodes: [{ type: "multipart/signed", parameters: { protocol: "application/pgp-signature" } }]
      }
    ]
  });
  assert.deepEqual(mixed, { signed: null, encrypted: null, verified: false });
});

test("treats only enveloped S/MIME types as encrypted", () => {
  const smime = (parameters: { [key: string]: string }) =>
    detectMessageSecurity({ type: "application/pkcs7-mime", parameters });
  assert.equal(smime({ "smime-type": "authEnveloped-data" }).encrypted, "smime");
  assert.equal(smime({ name: "smime.p7m" }).encrypted, "smime");
  for (const smimeType of ["compressed-data", "certs-only"]) {
    assert.deepEqual(smime({ "smime-type": smimeType, name: "smime.p7m" }), {
      signed: null, encrypted: null, verified: false
    });
  }
  assert.equal(smime({ name: "smime.p7c" }).encrypted, null);
  const signed = smime({ "smime-type": "signed-data", name: "smime.p7m" });
  assert.equal(signed.signed, "smime");
  assert.equal(signed.encrypted, null);
});
