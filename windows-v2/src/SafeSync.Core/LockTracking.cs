namespace SafeSync.Core;

public static class LockTracking
{
    public static FileIssue Update(FileEntry current,FileEntry? previous,FileIssue issue)
    {
        current.LockedSinceUtc=previous?.Status=="Locked" && previous.LockedSinceUtc.Length>0 ? previous.LockedSinceUtc : current.LastAttemptUtc;
        current.LockRetryCount=(previous?.Status=="Locked" ? previous.LockRetryCount : 0)+1;
        return issue with {WaitingSinceUtc=current.LockedSinceUtc,RetryCount=current.LockRetryCount,LastAttemptUtc=current.LastAttemptUtc};
    }
}
