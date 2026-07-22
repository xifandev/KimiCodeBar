namespace KimiCodeBar.Core;

/// <summary>
/// 轻量函数式结果类型，表示一个成功值或一个错误。
/// 用于不抛异常地传递服务层结果（如用量查询）。
/// </summary>
/// <typeparam name="T">成功时的结果类型。</typeparam>
/// <typeparam name="TError">失败时的错误类型（通常为枚举）。</typeparam>
public readonly struct Result<T, TError>
{
    /// <summary>成功时的值。</summary>
    public T? Value { get; }

    /// <summary>失败时的错误。</summary>
    public TError? Error { get; }

    /// <summary>是否成功。</summary>
    public bool IsSuccess { get; }

    private Result(T? value, TError? error, bool isSuccess)
    {
        Value = value;
        Error = error;
        IsSuccess = isSuccess;
    }

    /// <summary>创建一个成功结果。</summary>
    public static Result<T, TError> Ok(T value) => new(value, default, true);

    /// <summary>创建一个失败结果。</summary>
    public static Result<T, TError> Fail(TError error) => new(default, error, false);
}
