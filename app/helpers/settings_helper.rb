module SettingsHelper
  # The whole `claude mcp add` invocation, ready to paste. Built from
  # Current.external_base_url so it names the host and port this instance is
  # actually reachable on rather than a placeholder the reader has to edit.
  def mcp_add_command(token)
    <<~CMD.strip
      claude mcp add --transport http #{mcp_server_name} #{Current.external_base_url}/mcp --header "Authorization: Bearer #{token}"
    CMD
  end

  # The local name the MCP server gets in the client — arbitrary, and the user
  # can rename it. Derived from the host so someone running against more than
  # one Splat gets distinguishable entries instead of a collision on "splat".
  #
  # A leading "splat" label is skipped, so splat.booko.info reads as
  # "splat-booko" rather than "splat-splat".
  def mcp_server_name
    labels = Current.splat_host.to_s.split(":").first.to_s.split(".")
    labels.shift if labels.size > 1 && labels.first == "splat"
    label = labels.first

    (label.blank? || label == "localhost") ? "splat-dev" : "splat-#{label}"
  end
end
