import assert from "node:assert/strict";
import test from "node:test";
import { maxElements, sanitizeHtml } from "../src/mail/safeHtml.js";

const clean = (html: string, allow = false) =>
  sanitizeHtml(html, { allowRemoteImages: allow });

test("keeps formatting and tables", () => {
  const { html } = clean(
    '<table width="100%"><tr><td colspan="2" style="color:#333;font-weight:bold">Hi <b>there</b></td></tr></table><p>a &amp; b</p>'
  );
  assert.equal(
    html,
    '<table width="100%"><tr><td colspan="2" style="color:#333;font-weight:bold">Hi <b>there</b></td></tr></table><p>a &amp; b</p>'
  );
});

test("removes script, style, iframe, forms, inputs and handlers", () => {
  const { html } = clean(
    '<script>alert(1)</script><style>@import url(http://x/a.css)</style><link rel="stylesheet" href="http://x/a.css">' +
      '<iframe src="http://x"></iframe><object data="x"></object><embed src="x"><svg onload="alert(1)"><script>1</script></svg>' +
      '<form action="http://evil"><input name="p"><button>Go</button></form>' +
      '<p onclick="alert(1)" onmouseover="x()" class="c" id="i">ok</p><b onerror=alert(1)>b</b>'
  );
  assert.equal(html, 'Go<p>ok</p><b>b</b>');
  assert.doesNotMatch(html, /script|iframe|onclick|onerror|form|input|stylesheet|@import/i);
});

test("blocks javascript:, data: and obfuscated hrefs", () => {
  const cases = [
    "javascript:alert(1)",
    " JaVaScRiPt:alert(1)",
    "java\tscript:alert(1)",
    "java&#x09;script:alert(1)",
    "&#106;avascript:alert(1)",
    "data:text/html,<script>alert(1)</script>",
    "vbscript:x",
    "file:///etc/passwd"
  ];
  for (const href of cases) {
    const { html } = clean(`<a href="${href}">x</a>`);
    assert.equal(html, "<a>x</a>", href);
  }
  assert.equal(
    clean('<a href="https://example.com/a?b=1&c=2">x</a><a href="mailto:a@b.co">m</a>').html,
    '<a href="https://example.com/a?b=1&amp;c=2">x</a><a href="mailto:a@b.co">m</a>'
  );
});

test("strips dangerous css", () => {
  const { html } = clean(
    '<div style="background:url(http://x/t.png);color:red;position:fixed;width:expression(alert(1));background-color:red;font-family:\\75rl(x)">x</div>'
  );
  assert.equal(html, '<div style="color:red;background-color:red">x</div>');
});

test("remote images are stripped and counted by default", () => {
  const { html, remoteImageCount } = clean(
    '<img src="https://t.example/p.gif" width="1" height="1" alt="px">' +
      '<img src="http://t.example/a.png"><img src="//t.example/b.png" srcset="http://t.example/c.png 2x">' +
      '<div style="background-image:url(https://t.example/bg.png)" background="https://t.example/bg2.png">x</div>' +
      '<img src="cid:logo" alt="Logo">'
  );
  assert.equal(remoteImageCount, 3);
  assert.doesNotMatch(html, /t\.example|<img|srcset|background=/);
  assert.equal(html, 'px<div>x</div>Logo');
});

test("remote http(s) images survive only when explicitly allowed", () => {
  const { html, remoteImageCount } = clean(
    '<img src="https://t.example/p.png" onerror="x()"><img src="//t.example/b.png"><img src="javascript:alert(1)">',
    true
  );
  assert.equal(remoteImageCount, 2);
  assert.equal(html, '<img src="https://t.example/p.png">');
});

test("strips data images to alt text and does not count them as remote", () => {
  const png = "data:image/png;base64,iVBORw0KGgo=";
  const r = clean(`<img src="${png}" alt="x"><img src="data:image/svg+xml;base64,PHN2Zz4=">`);
  assert.equal(r.html, "x");
  assert.equal(r.remoteImageCount, 0);
});

test("escapes entities so decoded markup cannot reappear", () => {
  const { html } = clean("<p>&lt;script&gt;alert(1)&lt;/script&gt;</p><a title='\"><script>' href=\"https://a.co\">x</a>");
  assert.doesNotMatch(html, /<script/);
  assert.match(html, /&lt;script&gt;/);
});

test("handles broken and deeply nested input", () => {
  assert.doesNotMatch(clean("<p><b>unclosed <script>alert(1)").html, /script|alert/);
  const deep = "<div>".repeat(5000) + "x";
  assert.doesNotThrow(() => clean(deep));
});

test("keeps spaces in href path and query by encoding them, still blocks scheme obfuscation", () => {
  assert.equal(
    clean('<a href=" https://example.com/order details?id=hello world ">x</a>').html,
    '<a href="https://example.com/order%20details?id=hello%20world">x</a>'
  );
  assert.equal(
    clean('<a href="mailto:a@b.co?subject=hi there&amp;body=a b">m</a>').html,
    '<a href="mailto:a@b.co?subject=hi%20there&amp;body=a%20b">m</a>'
  );
  for (const href of ["java script:alert(1)", "javascript :alert(1)", " java\tscript:alert(1)", "java&#10;script:alert(1)", "\u0001javascript:alert(1)", "jav&#x09;ascript:alert(1)"]) {
    assert.equal(clean(`<a href="${href}">x</a>`).html, "<a>x</a>", href);
  }
});

test("returns empty html when the element budget is exceeded", () => {
  const ok = "<div>x</div>".repeat(maxElements);
  assert.match(clean(ok).html, /^<div>x<\/div>/);
  assert.equal(clean(ok + "<div>y</div>").html, "");
  assert.equal(clean("<span>a</span>".repeat(maxElements + 1)).html, "");
});

test("clamps colspan and rowspan", () => {
  assert.equal(clean('<table><tr><td colspan="99999" rowspan="0">x</td><td colspan="3">y</td></tr></table>').html,
    '<table><tr><td colspan="50" rowspan="1">x</td><td colspan="3">y</td></tr></table>');
});

test("keeps body background on a wrapper div", () => {
  assert.equal(clean('<body bgcolor="#000000"><p>x</p></body>').html,
    '<div style="background-color:#000000"><p>x</p></div>');
  assert.equal(clean('<body style="background-color:#111;color:red;background:url(x)"><p>x</p></body>').html,
    '<div style="background-color:#111"><p>x</p></div>');
  assert.equal(clean("<body><p>x</p></body>").html, "<p>x</p>");
});
