/// Web: settings come from the page URL instead.
String? envValue(String key) => Uri.base.queryParameters[key];
