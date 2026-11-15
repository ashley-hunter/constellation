import Testing
@testable import ConstellationCore

@Suite struct ReadOnlyCommandTests {
    @Test(arguments: [
        "ls",
        "ls -la src",
        "cat notes.md | head -20",
        "git status --short && git log --oneline -5 main",
        "git status --short; git log --oneline -5 main; git branch -a",
        "git -C ../repo diff --stat HEAD~1",
        "git --no-pager show HEAD:README.md",
        "git branch --merged main",
        "git remote -v",
        "git rev-parse --abbrev-ref HEAD 2>/dev/null || echo none",
        "LC_ALL=C grep -rn 'foo|bar' Sources > /dev/null 2>&1",
        "rg -n \"a; rm -rf b\" .",
        "find . -name '*.swift' -type f | wc -l",
        "sed -n '1,40p' Package.swift",
        "awk '{print $1}' data.txt | sort | head",
        "jq '.name' package.json",
        "node --version && python3 --version",
        "cd App && ls",
        "/bin/zsh -lc 'git status && ls'",
        "echo \"done\"",
        "diff a.txt b.txt; pwd; which swift; stat -f %z x; du -sh .; df -h; tree -L 2",
    ])
    func readOnlyLinesRunWithoutAsking(_ line: String) {
        #expect(ReadOnlyCommand.isReadOnly(line))
    }

    @Test(arguments: [
        "",
        "python3 notes.py list",
        "node build.js",
        "npm test",
        "npm install",
        "pip install requests",
        "./ls",
        "git status --short && git fetch -q 2>&1",
        "git push",
        "git branch new-feature",
        "git branch -D old",
        "git -c core.pager=sh log",
        "git log --output=log.txt",
        "ls > files.txt",
        "echo hi >> notes.md",
        "cat a | tee b",
        "rm -rf build",
        "mv a b",
        "cp a b",
        "sudo ls",
        "curl https://example.com",
        "wget https://example.com",
        "echo $(rm -rf /)",
        "echo `whoami`",
        "find . -name '*.tmp' -delete",
        "find . -exec rm {} \\;",
        "sed -i '' 's/a/b/' file",
        "sed 's/a/b/' file",
        "sed -n 's/a/b/w out' file",
        "awk 'BEGIN { system(\"rm x\") }'",
        "awk '{ print > \"out\" }' file",
        "rg --pre ./script foo",
        "cat <<EOF\nhi\nEOF",
        "echo 'unclosed",
        "ls # then rm",
        "bash -c 'rm -rf x'",
        "FOO=1 python3 x.py",
    ])
    func anythingElseStillAsks(_ line: String) {
        #expect(!ReadOnlyCommand.isReadOnly(line))
    }
}
