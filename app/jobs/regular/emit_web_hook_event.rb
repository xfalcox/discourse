# frozen_string_literal: true

require "excon"

module Jobs
  class EmitWebHookEvent < ::Jobs::Base
    sidekiq_options queue: "low"

    PING_EVENT = "ping"
    MAX_RETRY_COUNT = 4
    RETRY_BACKOFF = 5

    def execute(args)
      @arguments = args
      @retry_count = args[:retry_count] || 0
      @web_hook = WebHook.find_by(id: @arguments[:web_hook_id])
      validate_arguments!

      return if @web_hook.blank? # Web Hook was deleted

      unless ping_event?(@arguments[:event_type])
        validate_argument!(:payload)

        return if webhook_inactive?
        return if group_webhook_invalid?
        return if category_webhook_invalid?
        return if tag_webhook_invalid?
      end

      send_webhook!
    end

    private

    def validate_arguments!
      validate_argument!(:web_hook_id)
      validate_argument!(:event_type)
    end

    def validate_argument!(key)
      raise Discourse::InvalidParameters.new(key) if @arguments[key].blank?
    end

    def send_webhook!
      web_hook_body = build_webhook_body
      web_hook_event = create_webhook_event(web_hook_body)
      uri = URI(@web_hook.payload_url.strip)

      web_hook_headers = build_webhook_headers(uri, web_hook_body, web_hook_event)

      emitter = WebHookEmitter.new(@web_hook, web_hook_event)
      web_hook_response = emitter.emit!(headers: web_hook_headers, body: web_hook_body)

      publish_webhook_event(web_hook_event)
      process_webhook_response(web_hook_response)
    end

    def process_webhook_response(web_hook_response)
      return if web_hook_response&.status.blank?

      case web_hook_response.status
      when 200..299
      when 404, 410
        if @retry_count >= MAX_RETRY_COUNT
          @web_hook.update!(active: false)

          StaffActionLogger.new(Discourse.system_user).log_web_hook_deactivate(
            @web_hook,
            web_hook_response.status,
          )
        end
      else
        retry_web_hook
      end
    end

    def retry_web_hook
      if SiteSetting.retry_web_hook_events?
        @retry_count += 1
        return if @retry_count > MAX_RETRY_COUNT
        delay = RETRY_BACKOFF**(@retry_count - 1)
        @arguments[:retry_count] = @retry_count
        ::Jobs.enqueue_in(delay.minutes, :emit_web_hook_event, @arguments)
      end
    end

    def publish_webhook_event(web_hook_event)
      MessageBus.publish(
        "/web_hook_events/#{@web_hook.id}",
        { web_hook_event_id: web_hook_event.id, event_type: @arguments[:event_type] },
        group_ids: [Group::AUTO_GROUPS[:staff]],
      )
    end

    def ping_event?(event_type)
      PING_EVENT == event_type
    end

    def webhook_inactive?
      !@web_hook.active?
    end

    def group_webhook_invalid?
      @web_hook.group_ids.present? &&
        (@arguments[:group_ids].blank? || (@web_hook.group_ids & @arguments[:group_ids]).blank?)
    end

    def category_webhook_invalid?
      @web_hook.category_ids.present? &&
        (
          !@arguments[:category_id].present? ||
            !@web_hook.category_ids.include?(@arguments[:category_id])
        )
    end

    def tag_webhook_invalid?
      @web_hook.tag_ids.present? &&
        (@arguments[:tag_ids].blank? || (@web_hook.tag_ids & @arguments[:tag_ids]).blank?)
    end

    def build_webhook_headers(uri, web_hook_body, web_hook_event)
      content_type =
        case @web_hook.content_type
        when WebHook.content_types["application/x-www-form-urlencoded"]
          "application/x-www-form-urlencoded"
        else
          "application/json"
        end

      headers = {
        "Accept" => "*/*",
        "Connection" => "close",
        "Content-Length" => web_hook_body.bytesize.to_s,
        "Content-Type" => content_type,
        "Host" => uri.host,
        "User-Agent" => Discourse.user_agent,
        "X-Discourse-Instance" => Discourse.base_url,
        "X-Discourse-Event-Id" => web_hook_event.id.to_s,
        "X-Discourse-Event-Type" => @arguments[:event_type],
      }

      headers["X-Discourse-Event"] = @arguments[:event_name] if @arguments[:event_name].present?

      if @web_hook.secret.present?
        headers[
          "X-Discourse-Event-Signature"
        ] = "sha256=#{OpenSSL::HMAC.hexdigest("sha256", @web_hook.secret, web_hook_body)}"
      end

      headers
    end

    def build_webhook_body
      body = {}

      if ping_event?(@arguments[:event_type])
        body["ping"] = "OK"
      else
        body[@arguments[:event_type]] = JSON.parse(@arguments[:payload])
      end

      new_body = Plugin::Filter.apply(:after_build_web_hook_body, self, body)
      MultiJson.dump(new_body)
    end

    def create_webhook_event(web_hook_body)
      WebHookEvent.create!(web_hook: @web_hook, payload: web_hook_body)
    end
  end
end
