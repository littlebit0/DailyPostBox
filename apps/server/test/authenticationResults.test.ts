import assert from "node:assert/strict";
import test from "node:test";
import { parseAuthenticationFailures } from "../src/mail/authenticationResults.js";

const gmail = (rest: string) =>
  `Authentication-Results: mx.google.com;\r\n       ${rest}\r\n\r\n`;

test("gmail dmarc fail is reported", () => {
  const h = gmail("dkim=fail header.i=@x.test;\r\n spf=fail smtp.mailfrom=a@x.test;\r\n dmarc=fail (p=REJECT) header.from=x.test");
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), ["dmarc", "spf", "dkim"]);
});

test("passing mail has no warning", () => {
  const h = gmail("dkim=pass header.i=@x.test; spf=pass smtp.mailfrom=a@x.test; dmarc=pass header.from=x.test");
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), []);
});

test("dmarc pass hides stray dkim failure", () => {
  const h = gmail("dkim=fail header.i=@fwd.test; dkim=pass header.i=@x.test; dmarc=pass header.from=x.test");
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), []);
});

test("softfail is not reported", () => {
  assert.deepEqual(parseAuthenticationFailures(gmail("spf=softfail smtp.mailfrom=a@x.test"), "gmail"), []);
});

test("outlook protection host is trusted", () => {
  const h = "Authentication-Results: evil.example; spf=fail; dkim=none\r\n";
  assert.deepEqual(parseAuthenticationFailures(h, "outlook"), []);
  const h2 = "Authentication-Results: BN0PR01.protection.outlook.com; dmarc=fail action=none header.from=x.test\r\n";
  assert.deepEqual(parseAuthenticationFailures(h2, "outlook"), ["dmarc"]);
});

test("foreign authserv-id is ignored", () => {
  const h = "Authentication-Results: evil.test; dmarc=fail\r\n";
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), []);
});

test("forged lower header with trusted id is ignored when top header is foreign", () => {
  const h = "Authentication-Results: evil.test; dmarc=pass\r\nAuthentication-Results: mx.google.com; dmarc=fail\r\n";
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), []);
});

test("only the topmost header counts", () => {
  const h = "Authentication-Results: mx.google.com; dmarc=pass\r\nAuthentication-Results: mx.google.com; dmarc=fail\r\n";
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), []);
});

test("unverified providers are ignored", () => {
  const h = "Authentication-Results: mx.naver.com; dmarc=fail\r\n";
  assert.deepEqual(parseAuthenticationFailures(h, "naver"), []);
});

test("outlook header without authserv-id (Microsoft documented example)", () => {
  const h =
    "Authentication-Results: spf=fail smtp.mailfrom=contoso.com;\r\n dkim=fail header.d=contoso.com; dmarc=fail action=quarantine;\r\n compauth=fail reason=000\r\n";
  assert.deepEqual(parseAuthenticationFailures(h, "outlook"), ["dmarc", "spf", "dkim"]);
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), []);
});

test("quoted smtp.mailfrom cannot inject a fake dmarc=pass", () => {
  const h = gmail(
    'spf=fail smtp.mailfrom="x; dmarc=pass"@evil.test; dkim=fail header.i=@evil.test; dmarc=fail header.from=evil.test'
  );
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), ["dmarc", "spf", "dkim"]);
});

test("semicolon inside a (nested) comment does not split clauses", () => {
  const h = gmail("spf=fail (a; dmarc=pass (b; c)) smtp.mailfrom=a@x.test; dmarc=fail header.from=x.test");
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), ["dmarc", "spf"]);
});

test("conflicting results for one method: fail wins", () => {
  const h = gmail("dkim=pass header.i=@a.test; dkim=fail header.i=@b.test; dmarc=fail header.from=x.test");
  assert.deepEqual(parseAuthenticationFailures(h, "gmail"), ["dmarc", "dkim"]);
  assert.deepEqual(
    parseAuthenticationFailures(gmail("dmarc=pass header.from=a.test; dmarc=fail header.from=b.test"), "gmail"),
    ["dmarc"]
  );
});
