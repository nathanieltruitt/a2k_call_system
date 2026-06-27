# frozen_string_literal: true

require "set"

class A2kMeetSignalController < ApplicationController
  include A2kMeetHelpers
  ALLOWED_SIGNAL_TYPES = Set.new(
    %w[
      call_offer
      call_ringing
      call_answer
      call_reject
      call_end
      ice_candidate
      video_offer
      video_answer
      video_paused
      video_resumed
    ],
  ).freeze
  MAX_SIGNAL_PAYLOAD_BYTES = 64 * 1024
  DUPLICATE_NOTIFICATION_TTL = 30.seconds

  requires_login
  before_action :ensure_a2k_meet_enabled

  def send_signal
    if request.content_length.to_i > MAX_SIGNAL_PAYLOAD_BYTES
      return render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "payload_too_large"), status: 413
    end

    target = User.find_by(id: params[:target_user_id])
    raise Discourse::InvalidParameters.new(:target_user_id) if target.blank?

    # Non puoi chiamare te stesso
    if target.id == current_user.id
      return render json: failed_json.merge(message: I18n.t("a2k_meet.cannot_call_yourself"), reason: "cannot_call_yourself"), status: 403
    end

    unless a2k_meet_user_enabled?(current_user)
      return render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "caller_not_in_allowed_groups"), status: 403
    end
    unless a2k_meet_user_enabled?(target)
      return render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "target_not_in_allowed_groups"), status: 403
    end
    if SiteSetting.a2k_meet_require_follow? && !target_follows_current_user?(target)
      return render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "follow_required"), status: 403
    end

    signal_type = params[:signal_type].to_s
    unless ALLOWED_SIGNAL_TYPES.include?(signal_type)
      return render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "invalid_signal_type"), status: 400
    end

    perform_signal_rate_limits(target, signal_type)

    payload = signal_params
    if payload_too_large?(payload)
      return render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "payload_too_large"), status: 413
    end

    # Caller identity metadata is server-owned. Do not trust client-supplied avatar/from-user fields.
    payload.delete("avatar_template")
    payload.delete("from_user_id")
    if signal_type == "call_offer"
      payload["avatar_template"] = current_user.avatar_template
    end

    # MessageBus: push in tempo reale allo smartphone/desktop del destinatario (squillo, UI chiamata).
    # Indipendente dalle notifiche Discourse (campanella).
    message = {
      "from_user_id" => current_user.id,
      "from_username" => current_user.username,
      "signal_type" => signal_type,
      "payload" => payload,
    }
    MessageBus.publish(
      "/a2k-meet/signals",
      message,
      user_ids: [target.id],
    )

    # Notifica Discourse (campanella)
    if signal_type == "call_offer"
      create_incoming_call_notification(target, current_user) unless duplicate_incoming_notification?(target, current_user)
    elsif signal_type == "call_end" && payload["reason"].to_s == "no_answer"
      create_missed_call_notification(target, current_user)
    end

    render json: success_json
  rescue RateLimiter::LimitExceeded
    render json: failed_json.merge(message: I18n.t("a2k_meet.not_allowed"), reason: "rate_limited"), status: 429
  end

  private

  def ensure_a2k_meet_enabled
    raise Discourse::NotFound unless SiteSetting.a2k_meet_enabled?
  end

  def signal_params
    raw = params.permit(payload: { sdp: {}, candidate: {}, quality: [], reason: {} }).fetch(:payload, {})
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.stringify_keys : raw.to_h.stringify_keys
  rescue StandardError
    {}
  end

  def payload_too_large?(payload)
    JSON.generate(payload).bytesize > MAX_SIGNAL_PAYLOAD_BYTES
  rescue JSON::GeneratorError
    true
  end

  def perform_signal_rate_limits(target, signal_type)
    RateLimiter.new(current_user, "a2k_meet_signal", 120, 1.minute).performed!
    RateLimiter.new(current_user, "a2k_meet_signal_target_#{target.id}", 30, 1.minute).performed!
    return unless signal_type == "call_offer"

    RateLimiter.new(current_user, "a2k_meet_call_offer_target_#{target.id}", 3, 1.minute).performed!
  end

  def duplicate_incoming_notification?(callee, caller)
    key = "a2k_meet_incoming_notification_#{caller.id}_#{callee.id}"
    return true if Rails.cache.exist?(key)

    Rails.cache.write(key, true, expires_in: DUPLICATE_NOTIFICATION_TTL)
    false
  rescue StandardError => e
    Rails.logger.warn("a2k-meet: duplicate notification check failed (allowing notification): #{e.message}")
    false
  end

  def create_incoming_call_notification(callee, caller)
    full_message = I18n.t("a2k_meet.calling_you_short", default: "is calling you")
    title_short = I18n.t("a2k_meet.incoming_call_title", default: "Incoming call")
    base_url = Discourse.base_url.presence || "/"
    custom_url = base_url.end_with?("/") ? "#{base_url}?a2k_meet=notifications&a2k_meet_tab=received" : "#{base_url}/?a2k_meet=notifications&a2k_meet_tab=received"
    event_at = Time.current.utc.iso8601

    types = Notification.types
    data_hash = {
      "display_username" => caller.username,
      "username" => caller.username,
      "message" => full_message,
      "notification_message" => full_message,
      "customMessage" => full_message,
      "customTranslatedTitle" => title_short,
      "customIcon" => "phone",
      "customUrl" => custom_url,
      "a2k_meet_incoming" => true,
      "from_user_id" => caller.id,
      "event_at" => event_at,
    }

    custom_type = types[:custom] if types.key?(:custom)
    custom_type ||= 14 # valore standard :custom se l’Enum non espone la chiave
    Notification.create!(
      notification_type: custom_type,
      user_id: callee.id,
      topic_id: nil,
      post_number: nil,
      high_priority: true,
      data: data_hash.to_json,
    )
    Rails.logger.info("a2k-meet: incoming call notification created for user_id=#{callee.id} from #{caller.username} (user_id=#{caller.id})")
  rescue StandardError => e
    Rails.logger.warn("a2k-meet: could not create notification: #{e.message}")
  end

  def create_missed_call_notification(callee, caller)
    full_message = I18n.t("a2k_meet.missed_call_short", default: "Missed a call")
    title_short = I18n.t("a2k_meet.missed_call_title", default: "Missed call")
    base_url = Discourse.base_url.presence || "/"
    custom_url = base_url.end_with?("/") ? "#{base_url}?a2k_meet=notifications&a2k_meet_tab=missed" : "#{base_url}/?a2k_meet=notifications&a2k_meet_tab=missed"
    event_at = Time.current.utc.iso8601

    types = Notification.types
    data_hash = {
      "display_username" => caller.username,
      "username" => caller.username,
      "message" => full_message,
      "notification_message" => full_message,
      "customMessage" => full_message,
      "customTranslatedTitle" => title_short,
      "customIcon" => "phone-slash",
      "customUrl" => custom_url,
      "a2k_meet_missed" => true,
      "from_user_id" => caller.id,
      "event_at" => event_at,
    }

    custom_type = types[:custom] if types.key?(:custom)
    custom_type ||= 14
    Notification.create!(
      notification_type: custom_type,
      user_id: callee.id,
      topic_id: nil,
      post_number: nil,
      high_priority: false,
      data: data_hash.to_json,
    )
    Rails.logger.info("a2k-meet: missed call notification created for user_id=#{callee.id} from #{caller.username} (user_id=#{caller.id})")
  rescue StandardError => e
    Rails.logger.warn("a2k-meet: could not create missed call notification: #{e.message}")
  end
end
