module SettingsHelper
  # The whole `claude mcp add` invocation, ready to paste. Built from
  # Current.external_base_url so it names the host and port this instance is
  # actually reachable on rather than a placeholder the reader has to edit.
  def mcp_add_command(token)
    "#{mcp_add_command_prefix}#{token}\""
  end

  # Everything in the command up to the token itself, so the view can render the
  # token as its own element and mask it until asked. Kept here rather than in
  # the view so the displayed command and the copied one cannot drift apart.
  def mcp_add_command_prefix
    %(claude mcp add --transport http #{mcp_server_name} #{Current.external_base_url}/mcp --header "Authorization: Bearer )
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

  # A full 40-character SHA is unreadable and wide enough to shoulder its
  # neighbours out of the About grid; the first 12 identify a commit fine. Only
  # hex is shortened — a tag or "unknown" is shown as-is.
  def short_revision(revision)
    revision.to_s.match?(/\A[0-9a-f]{13,40}\z/i) ? revision[0, 12] : revision
  end
end
