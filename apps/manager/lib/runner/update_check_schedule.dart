/// When an automatic update check is due: the last result is older than
/// [interval] (or there is none) and no attempt started within [retry], so
/// a failing source is not asked again at every opportunity.
final class UpdateCheckSchedule {
  const UpdateCheckSchedule({
    this.interval = const Duration(hours: 6),
    this.retry = const Duration(minutes: 15),
  });
  final Duration interval, retry;
  bool due(DateTime now, {DateTime? checkedAt, DateTime? attemptedAt}) =>
      (attemptedAt == null || now.difference(attemptedAt) >= retry) &&
      (checkedAt == null || now.difference(checkedAt) >= interval);
}
