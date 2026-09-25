/// Web: settings come from the page URL; the console line is the output.
String? envValue(String key) => Uri.base.queryParameters[key];

void writeResult(String json) {}

void exitApp() {}
