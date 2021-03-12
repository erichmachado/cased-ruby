# frozen_string_literal: true

require 'cased/cli/session'

module Cased
  module CLI
    # InteractiveSession is responsible for initiating a Cased CLI session and
    # responding to all its possible states.
    #
    # InteractiveSession is intended to be used where a TTY is present to handle
    # the entire flow from authentication, reason required, waiting for
    # approval, canceled, or timed out.
    class InteractiveSession
      def self.start(reason: nil, command: nil, metadata: {})
        return Cased::CLI::Session.current if Cased::CLI::Session.current&.approved?

        Cased::CLI::Log.log 'Running under Cased CLI.'

        new(reason: reason, command: command, metadata: metadata).create
      end

      attr_reader :session

      def initialize(reason: nil, command: nil, metadata: {})
        @session = Cased::CLI::Session.new(
          reason: reason,
          command: command,
          metadata: metadata,
        )
      end

      def create
        signal_handler = Signal.trap('SIGINT') do
          if session.requested?
            Cased::CLI::Log.log 'Exiting and canceling request…'
            session.cancel
            exit 0
          elsif signal_handler.respond_to?(:call)
            # We need to call the original handler if we exit this interactive
            # session successfully
            signal_handler.call
          else
            raise Interrupt
          end
        end

        if session.create
          handle_state(session.state)
        elsif session.unauthorized?
          if session.authentication.exists?
            Cased::CLI::Log.log "Existing credentials at #{session.authentication.credentials_path} are not valid."
          else
            Cased::CLI::Log.log "Could not find credentials at #{session.authentication.credentials_path}, looking up now…"
          end

          identity = Cased::CLI::Identity.new
          session.authentication.token = identity.identify

          create
        elsif session.reason_required?
          reason_prompt && create
        else
          Cased::CLI::Log.log 'Could not start CLI session.'
          exit 1 if Cased.config.guard_deny_if_unreachable?
        end

        session
      end

      private

      def reason_prompt
        print Cased::CLI::Log.string 'Please enter a reason for access: '
        session.reason = STDIN.gets.chomp
      end

      def wait_for_approval
        sleep 1
        session.refresh && handle_state(session.state)
      end

      def waiting_for_approval_message
        return if defined?(@waiting_for_approval_message_displayed)

        motd = session.guard_application.dig('settings', 'message_of_the_day')
        waiting_message = motd.blank? ? 'Approval request sent…' : motd
        Cased::CLI::Log.log "#{waiting_message} (id: #{session.id})"
        @waiting_for_approval_message_displayed = true
      end

      def handle_state(state)
        case state
        when 'approved'
          Cased::CLI::Log.log 'CLI session has been approved'
          session.record
        when 'requested'
          waiting_for_approval_message
          wait_for_approval
        when 'denied'
          Cased::CLI::Log.log 'CLI session has been denied'
          exit 1
        when 'timed_out'
          Cased::CLI::Log.log 'CLI session has timed out'
        when 'canceled'
          Cased::CLI::Log.log 'CLI session has been canceled'
        end
      end
    end
  end
end
