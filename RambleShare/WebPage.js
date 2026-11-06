// Safari runs this in the page when it's shared to 随口记, and hands the result to the extension:
// what's selected, or the words of the whole page. Nothing else on the page is read or changed.
var WebPage = function() {};

WebPage.prototype = {
    run: function(parameters) {
        parameters.completionFunction({
            "title": document.title,
            "url": document.URL,
            "selection": String(window.getSelection()),
            "text": document.body ? document.body.innerText.slice(0, 200000) : ""
        });
    }
};

var ExtensionPreprocessingJS = new WebPage;
