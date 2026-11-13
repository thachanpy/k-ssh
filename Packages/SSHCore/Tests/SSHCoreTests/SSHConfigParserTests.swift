import XCTest

@testable import SSHCore

final class SSHConfigParserTests: XCTestCase {
    private func parse(
        _ text: String, include: @escaping SSHConfigParser.IncludeLoader = { _ in [] }
    ) -> SSHConfigResult {
        SSHConfigParser.parse(text, homeDirectory: "/Users/me", localUser: "me", includeLoader: include)
    }

    private func host(_ result: SSHConfigResult, _ alias: String) throws -> SSHConfigHost {
        try XCTUnwrap(result.hosts.first { $0.alias == alias }, "missing host \(alias)")
    }

    func testBasicHost() throws {
        let result = parse(
            """
            Host web
                HostName 10.0.0.5
                User deploy
                Port 2222
            """)
        let web = try host(result, "web")
        XCTAssertEqual(web.hostName, "10.0.0.5")
        XCTAssertEqual(web.user, "deploy")
        XCTAssertEqual(web.port, 2222)
        XCTAssertEqual(web.effectiveHostName, "10.0.0.5")
    }

    func testAliasIsHostNameWhenHostNameMissing() throws {
        let web = try host(parse("Host example.com\n  User bob"), "example.com")
        XCTAssertNil(web.hostName)
        XCTAssertEqual(web.effectiveHostName, "example.com")
    }

    func testKeywordsAreCaseInsensitive() throws {
        let web = try host(parse("HOST web\n  hostname h\n  USER u\n  pOrT 99"), "web")
        XCTAssertEqual(web.hostName, "h")
        XCTAssertEqual(web.user, "u")
        XCTAssertEqual(web.port, 99)
    }

    func testEqualsSignForm() throws {
        let web = try host(parse("Host=web\nHostName = h.example\nPort=2200"), "web")
        XCTAssertEqual(web.hostName, "h.example")
        XCTAssertEqual(web.port, 2200)
    }

    func testCommentsAndBlankLinesAreIgnored() throws {
        let result = parse(
            """
            # leading comment

            Host a   # trailing comment
                # inside
                HostName a.example # why not
            """)
        XCTAssertEqual(result.hosts.map(\.alias), ["a"])
        XCTAssertEqual(result.hosts[0].hostName, "a.example")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testQuotedValuesKeepSpaces() throws {
        let web = try host(parse("Host web\n  IdentityFile \"/Users/me/My Keys/id\""), "web")
        XCTAssertEqual(web.identityFiles, ["/Users/me/My Keys/id"])
    }

    func testMultiplePatternsOnOneHostLine() {
        let result = parse("Host a b c\n  User x")
        XCTAssertEqual(result.hosts.map(\.alias), ["a", "b", "c"])
        XCTAssertTrue(result.hosts.allSatisfy { $0.user == "x" })
    }

    func testWildcardOnlyBlocksAreDefaultsNotListed() throws {
        let result = parse(
            """
            Host web
                HostName w
            Host *
                User fallback
                Port 2200
            """)
        XCTAssertEqual(result.hosts.map(\.alias), ["web"])
        let web = try host(result, "web")
        XCTAssertEqual(web.user, "fallback")
        XCTAssertEqual(web.port, 2200)
    }

    func testFirstMatchWins() throws {
        let result = parse(
            """
            Host web
                User first
            Host *
                User second
            Host web
                User third
            """)
        XCTAssertEqual(try host(result, "web").user, "first")
    }

    func testGlobalOptionsBeforeAnyHostApplyToAll() throws {
        let result = parse(
            """
            User globaluser
            Host a
                HostName a.example
            """)
        XCTAssertEqual(try host(result, "a").user, "globaluser")
    }

    func testPatternWildcardBlockAppliesToMatchingAliases() throws {
        let result = parse(
            """
            Host prod-web prod-db staging
                HostName x
            Host prod-*
                User prodadmin
            """)
        XCTAssertEqual(try host(result, "prod-web").user, "prodadmin")
        XCTAssertEqual(try host(result, "prod-db").user, "prodadmin")
        XCTAssertNil(try host(result, "staging").user)
    }

    func testQuestionMarkPattern() throws {
        let result = parse("Host a1 a22\n  HostName x\nHost a?\n  User single")
        XCTAssertEqual(try host(result, "a1").user, "single")
        XCTAssertNil(try host(result, "a22").user)
    }

    func testNegationExcludesHost() throws {
        let result = parse(
            """
            Host web1 web2
                HostName x
            Host * !web2
                User allbutweb2
            """)
        XCTAssertEqual(try host(result, "web1").user, "allbutweb2")
        XCTAssertNil(try host(result, "web2").user)
    }

    func testIdentityFileAccumulatesAndExpandsTokens() throws {
        let result = parse(
            """
            Host web
                HostName w.example
                User deploy
                IdentityFile ~/.ssh/id_%h
                IdentityFile ~/.ssh/%n_%r_%u
            Host *
                IdentityFile ~/.ssh/default
            """)
        XCTAssertEqual(
            try host(result, "web").identityFiles,
            [
                "/Users/me/.ssh/id_w.example",
                "/Users/me/.ssh/web_deploy_me",
                "/Users/me/.ssh/default",
            ])
    }

    func testPercentPercentIsLiteralPercent() throws {
        let web = try host(parse("Host web\n  IdentityFile /k/100%%"), "web")
        XCTAssertEqual(web.identityFiles, ["/k/100%"])
    }

    func testProxyJumpChain() throws {
        let result = parse("Host target\n  ProxyJump alice@bastion1:2200, bastion2")
        XCTAssertEqual(try host(result, "target").proxyJump, ["alice@bastion1:2200", "bastion2"])
    }

    func testProxyJumpNoneDisablesInheritedJump() throws {
        let result = parse(
            """
            Host direct
                ProxyJump none
            Host *
                ProxyJump gateway
            """)
        XCTAssertEqual(try host(result, "direct").proxyJump, [])
    }

    func testIncludeIsInlinedWithGlobs() throws {
        let files: [String: [String]] = [
            "conf.d/*": ["Host included\n  HostName inc.example", "Host included2\n  HostName inc2.example"]
        ]
        let result = parse(
            """
            Include conf.d/*
            Host main
                HostName main.example
            """,
            include: { files[$0] ?? [] })
        XCTAssertEqual(result.hosts.map(\.alias), ["included", "included2", "main"])
    }

    func testNestedIncludeAndDepthLimit() throws {
        // A file that includes itself must terminate.
        let result = parse(
            "Include loop\nHost a\n  HostName a",
            include: { _ in ["Include loop\nHost looped\n  HostName l"] })
        XCTAssertTrue(result.hosts.contains { $0.alias == "a" })
        XCTAssertTrue(result.hosts.contains { $0.alias == "looped" })
    }

    func testUnsupportedKeywordsProduceWarningsOnce() {
        let result = parse(
            """
            Host a
                ForwardAgent yes
                ForwardAgent no
                ServerAliveInterval 30
            """)
        XCTAssertEqual(result.hosts.map(\.alias), ["a"])
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("forwardagent") })
    }

    func testMatchBlocksAreIgnoredWithWarning() throws {
        let result = parse(
            """
            Host a
                HostName a.example
            Match host a
                User shouldnotapply
            """)
        XCTAssertNil(try host(result, "a").user)
        XCTAssertTrue(result.warnings.contains { $0.contains("Match") })
    }

    func testDuplicateAliasListedOnce() {
        let result = parse("Host a\n  User one\nHost a\n  Port 1")
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].user, "one")
        XCTAssertEqual(result.hosts[0].port, 1)
    }

    func testInvalidPortIsIgnored() throws {
        XCTAssertNil(try host(parse("Host a\n  Port abc"), "a").port)
    }

    func testGlobMatchHelper() {
        XCTAssertTrue(SSHConfigParser.globMatch("*", "anything"))
        XCTAssertTrue(SSHConfigParser.globMatch("a*c", "abbbc"))
        XCTAssertTrue(SSHConfigParser.globMatch("A?C", "abc"))
        XCTAssertFalse(SSHConfigParser.globMatch("a?c", "ac"))
        XCTAssertFalse(SSHConfigParser.globMatch("abc", "abcd"))
    }
}
