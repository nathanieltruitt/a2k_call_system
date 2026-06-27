# frozen_string_literal: true

# name: a2k-meet
# about: P2P voice calls (WebRTC) with built-in UI. One plugin, no theme component. Signaling via MessageBus; admin can restrict by group and set incoming call sound.
# version: 0.3.0-beta
# authors: A2K
# url: https://github.com/a2k-meet/a2k-meet

enabled_site_setting :a2k_meet_enabled

# I file in assets/javascripts sono inclusi automaticamente nei bundle (Discourse 2026+). Non usare register_asset per JS.
register_asset "stylesheets/common/a2k-meet.scss"

# Variabile CSS colore principale (iniettata in :root per sovrascrivere il default nello SCSS)
if respond_to?(:register_html_builder)
  register_html_builder(:head) do
    primary = SiteSetting.a2k_meet_primary_color.presence || "#13c98c"
    primary = "#13c98c" unless primary.to_s.match?(/\A#[0-9a-fA-F]{6}\z/)
    hex = primary.to_s.strip.sub(/\A#/, "")
    dark = if hex.length == 6
      r = (hex[0..1].to_i(16) * 0.72).round.clamp(0, 255)
      g = (hex[2..3].to_i(16) * 0.72).round.clamp(0, 255)
      b = (hex[4..5].to_i(16) * 0.72).round.clamp(0, 255)
      format("#%02x%02x%02x", r, g, b)
    else
      "#0f8f6a"
    end
    "<style data-discourse-plugin=\"a2k-meet\">:root{--a2k-meet-primary:#{primary};--a2k-meet-primary-dark:#{dark};}</style>".html_safe
  end
end

after_initialize do
  require_relative "app/controllers/concerns/a2k_meet_helpers"
  require_relative "app/controllers/a2k_meet_controller"
  require_relative "app/controllers/a2k_meet_signal_controller"

  begin
    if User.respond_to?(:register_custom_field_type)
      User.register_custom_field_type("a2k_meet_enabled", :boolean)
      User.register_custom_field_type("a2k_meet_selected_custom_ringtone_index", :integer)
    end
  rescue NameError, ArgumentError, StandardError => e
    Rails.logger.warn("a2k-meet: skip register_custom_field_type: #{e.message}")
  end

  Discourse::Application.routes.append do
    get "a2k-meet/status" => "a2k_meet#status"
    put "a2k-meet/preferences" => "a2k_meet#preferences"
    get "a2k-meet/can-call/:user_id" => "a2k_meet#can_call"
    post "a2k-meet/signal" => "a2k_meet_signal#send_signal"
    get "a2k-meet/watermark.png" => "a2k_meet#watermark"
  end
end
