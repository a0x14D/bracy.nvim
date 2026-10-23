var assert = require("assert");
var FileManager = require("../filemanager.js");

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
});
