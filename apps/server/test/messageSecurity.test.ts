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
