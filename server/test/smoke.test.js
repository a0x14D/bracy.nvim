var assert = require("assert");
var http = require("http");
var FileManager = require("../filemanager.js");
var Server = require("../server.js");

describe("bracey server smoke tests", function () {
	it("loads all server modules", function () {
		assert.doesNotThrow(function () {
			require("../htmlfile.js");
			require("../cssfile.js");
			require("../server.js");
		});
	});

	it("creates an html file and injects the client", function () {
		var fm = new FileManager();
		fm.newFile("1", "index.html", "/tmp/index.html", "html", "<html><body><p>hi</p></body></html>");
		var file = fm.getById("1");
		assert.ok(file);
		var webSrc = file.webSrc();
		assert.ok(webSrc.indexOf("meta-bracey-element-index") !== -1, "should inject element index attributes");
	});

	it("highlights the tag under the cursor", function () {
		var fm = new FileManager();
		fm.newFile("1", "index.html", "/tmp/index.html", "html", "<html><body><p>hi</p></body></html>");
		var file = fm.getById("1");
		var tag = file.tagFromPosition(1, 13); // inside <p>
		assert.ok(tag);
		assert.strictEqual(tag.name, "p");
	});

	it("resolves css selectors from a position", function () {
		var fm = new FileManager();
		fm.newFile("2", "style.css", "/tmp/style.css", "css", ".foo { color: red; }");
		var file = fm.getById("2");
		assert.strictEqual(file.selectorFromPosition(0, 0), ".foo");
	});

	it("answers the readiness probe with its session token", function (done) {
		this.timeout(5000);
		var port = 14500 + Math.floor(Math.random() * 1000);
		var srv = new Server({
			port: port,
			"web-address": "127.0.0.1",
			"editor-address": "127.0.0.1",
			token: "abc123",
		});
		srv.start();
		setTimeout(function () {
			http
				.get({ host: "127.0.0.1", port: port, path: "/__bracey_health" }, function (res) {
					var body = "";
					res.on("data", function (chunk) {
						body += chunk;
					});
					res.on("end", function () {
						try {
							assert.strictEqual(body, "abc123");
						} finally {
							srv.stop();
							done();
						}
					});
				})
				.on("error", function (err) {
					srv.stop();
					done(err);
				});
		}, 300);
	});
});
