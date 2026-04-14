param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$CommitMessage
)

git add .
git commit -m "$CommitMessage"
git push