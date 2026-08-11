# frozen_string_literal: true

# Say out loud, once at boot, what the auth configuration actually adds up to.
#
# Every one of these states is otherwise silent: a half-set provider looks like
# an open instance, an empty allowlist looks like a provider problem, and an
# allowlist with no provider looks like it's doing something. A line in the log
# at startup is cheaper than working any of them out from the outside.
#
# after_initialize because SplatAuthorization is autoloaded.
Rails.application.config.after_initialize do
  case SplatAuthorization.oidc_state
  when :misconfigured
    Rails.logger.error(
      "[auth] OIDC is half-configured — missing #{SplatAuthorization.missing_oidc_vars.join(", ")}. " \
      "The UI returns 503 until all of #{SplatAuthorization::OIDC_VARS.join(", ")} are set " \
      "(or all are unset, to run open). Ingestion, /_health and /mcp are unaffected."
    )
  when :enforcing
    unless SplatAuthorization.allowlist_configured?
      Rails.logger.warn(
        "[auth] OIDC is configured but neither #{SplatAuthorization::ALLOWLIST_VARS.join(" nor ")} is set — " \
        "every login will be denied after the provider round trip."
      )
    end
  when :open
    if SplatAuthorization.allowlist_without_provider?
      Rails.logger.warn(
        "[auth] #{SplatAuthorization::ALLOWLIST_VARS.join(" / ")} is set but no OIDC provider is configured — " \
        "nothing is enforcing the allowlist and Splat is serving unauthenticated."
      )
    end
  end
end
