namespace LocationTracker.Api.Common;

public record ApiError(string Message, IReadOnlyDictionary<string, string[]>? Errors = null);
