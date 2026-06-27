/**
 * Plugin a2k-meet: invio segnali (A2kMeetSend), status, e ricezione via MessageBus.
 * La UI è in a2k-meet-ui.js (stesso plugin).
 */
import { apiInitializer } from "discourse/lib/api";
import MessageBus from "message-bus-client";
import { ajax } from "discourse/lib/ajax";

const LOG = (...args) => console.log("[a2k-meet glue]", ...args);

apiInitializer("0.7", (api) => {
  const currentUser = api.getCurrentUser();

  window.A2kMeetAllowed = false;
  window.A2kMeetStatusLoaded = false;

  window.A2kMeetSend = (data) => {
    if (!currentUser) {
      LOG("glue: A2kMeetSend called but no current user");
      return Promise.reject(new Error("a2k-meet: not logged in"));
    }
    const { to_user_id, type, ...rest } = data;
    LOG("glue: A2kMeetSend called", type, "to_user_id", to_user_id, "payload keys", Object.keys(rest || {}));
    const promise = ajax("/a2k-meet/signal", {
      type: "POST",
      data: { target_user_id: to_user_id, signal_type: type, payload: rest },
    });
    promise.then(
      () => LOG("glue: signal OK", type, "to_user_id", to_user_id),
      (err) => LOG("glue: signal FAIL", type, "to_user_id", to_user_id, err)
    );
    return promise;
  };
  LOG("glue: A2kMeetSend registered (currentUser:", currentUser ? currentUser.username : "none", ")");

  if (!currentUser) return;

  ajax("/a2k-meet/status")
    .then((data) => {
      window.A2kMeetStatusLoaded = true;
      window.A2kMeetAllowed = data.enabled === true;
      window.A2kMeetVideoAllowed = data.video_allowed === true;
      window.A2kMeetShowFloatingButton = data.show_floating_button !== false;
      window.A2kMeetShowChatButton = data.show_chat_button !== false;
      window.A2kMeetIncomingSound = (data.incoming_sound && data.incoming_sound !== "") ? data.incoming_sound : "default";
      window.A2kMeetCustomRingtoneUrl = (data.custom_ringtone_url && data.custom_ringtone_url !== "") ? data.custom_ringtone_url : "";
      window.A2kMeetIceServers = Array.isArray(data.ice_servers) && data.ice_servers.length > 0 ? data.ice_servers : null;
      LOG("glue: status OK enabled=", window.A2kMeetAllowed, "ice_servers=", window.A2kMeetIceServers ? "custom" : "default");
      window.dispatchEvent(
        new CustomEvent("a2k-meet-allowed-changed", {
          detail: { allowed: window.A2kMeetAllowed },
        })
      );
    })
    .catch((err) => {
      window.A2kMeetStatusLoaded = true;
      window.A2kMeetAllowed = false;
      window.A2kMeetShowFloatingButton = true;
      window.A2kMeetShowChatButton = true;
      window.A2kMeetIncomingSound = "default";
      window.A2kMeetCustomRingtoneUrl = "";
      window.A2kMeetIceServers = null;
      LOG("glue: status FAIL", err);
      window.dispatchEvent(
        new CustomEvent("a2k-meet-allowed-changed", {
          detail: { allowed: false },
        })
      );
    });

  MessageBus.subscribe("/a2k-meet/signals", (data) => {
    LOG("glue: MessageBus message received", data.signal_type, "from_user_id", data.from_user_id, "from_username", data.from_username);
    const payload = data.payload || {};
    const detail = {
      ...payload,
      type: data.signal_type,
      from_user_id: data.from_user_id,
      from_username: data.from_username,
      sdp: payload.sdp != null ? payload.sdp : data.sdp,
      avatar_template: payload.avatar_template != null ? payload.avatar_template : data.avatar_template,
      candidate: payload.candidate != null ? payload.candidate : data.candidate,
    };
    LOG("glue: dispatching a2k-meet-signal", detail.type, "hasSdp?", !!detail.sdp, "hasCandidate?", !!detail.candidate);
    window.dispatchEvent(new CustomEvent("a2k-meet-signal", { detail }));
  });
  window.A2kMeetMessageBusSubscribed = true;
  LOG("glue: MessageBus subscribed to /a2k-meet/signals");
});
