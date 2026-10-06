import 'package:cloud_functions/cloud_functions.dart';

/// A server rate-limit rejection (`resource-exhausted` from
/// functions/rate-limit.js) carrying the seconds the client should wait.
/// Screens catch this to show a minutes-accurate message instead of the
/// generic "check the network and try again" copy (review finding HIGH-2).
class RateLimitExceededException implements Exception {
  const RateLimitExceededException([this.retryAfterSec]);

  final int? retryAfterSec;

  /// Plain-language, minutes-rounded message (DESIGN.md §5 copy style).
  String get message {
    final sec = retryAfterSec;
    if (sec == null || sec <= 0) {
      return 'That action hit its hourly limit \u2014 try again in a few minutes.';
    }
    final minutes = (sec / 60).ceil();
    if (minutes <= 1) {
      return 'That action hit its hourly limit \u2014 try again in a minute.';
    }
    return 'That action hit its hourly limit \u2014 try again in $minutes minutes.';
  }
}

/// Returns a [RateLimitExceededException] when [error] is the server's
/// `resource-exhausted` rate-limit response, otherwise null (so callers can
/// fall back to their generic error handling).
RateLimitExceededException? rateLimitOf(Object error) {
  if (error is! FirebaseFunctionsException || error.code != 'resource-exhausted') {
    return null;
  }
  final details = error.details;
  final sec = details is Map ? details['retryAfterSec'] : null;
  return RateLimitExceededException(sec is int ? sec : (sec is num ? sec.toInt() : null));
}
