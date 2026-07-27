import Testing

@testable import PanewrightCore

@Suite struct DefaultsCarryNoPersonalDataTests {
    /// The shipped defaults are the dogfooded config — which makes it worth
    /// asserting forever that the dogfooding never leaks *personal* values
    /// into them: no integration hosts, no account emails, no employer
    /// domains. A fresh install's config must be anonymous.
    @Test func defaultTomlHasNoIntegrationsOrIdentity() {
        let toml = PanewrightConfigSerializer.emit(.default)
        #expect(!toml.contains("[integrations"))
        #expect(!toml.contains("@"))
        #expect(!toml.lowercased().contains("bearflag"))
        #expect(!toml.lowercased().contains("nitsch"))
    }

    @Test func defaultServicesAreAllBlank() {
        let integrations = PanewrightConfig.default.integrations
        for service in [
            integrations.github, integrations.gitlab, integrations.bitbucket,
            integrations.jira, integrations.confluence, integrations.teams,
        ] {
            #expect(!service.enabled)
            #expect(service.host.isEmpty)
            #expect(service.user.isEmpty)
        }
    }
}
