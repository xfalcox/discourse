# frozen_string_literal: true

RSpec.describe UserDestroyer do
  fab!(:user) { Fabricate(:user_with_secondary_email, refresh_auto_groups: true) }
  fab!(:admin)

  describe ".new" do
    it "raises an error when user is nil" do
      expect { UserDestroyer.new(nil) }.to raise_error(Discourse::InvalidParameters)
    end

    it "raises an error when user is not a User" do
      expect { UserDestroyer.new(5) }.to raise_error(Discourse::InvalidParameters)
    end
  end

  describe "#destroy" do
    it "raises an error when user is nil" do
      expect { UserDestroyer.new(admin).destroy(nil) }.to raise_error(Discourse::InvalidParameters)
    end

    it "raises an error when user is not a User" do
      expect { UserDestroyer.new(admin).destroy("nothing") }.to raise_error(
        Discourse::InvalidParameters,
      )
    end

    it "raises an error when regular user tries to delete another user" do
      expect { UserDestroyer.new(user).destroy(Fabricate(:user)) }.to raise_error(
        Discourse::InvalidAccess,
      )
    end

    shared_examples "successfully destroy a user" do
      it "should delete the user" do
        expect { destroy }.to change { User.count }.by(-1)
      end

      it "should return the deleted user record" do
        return_value = destroy
        expect(return_value).to eq(user)
        expect(return_value).to be_destroyed
      end

      it "should log the action" do
        StaffActionLogger.any_instance.expects(:log_user_deletion).with(user, anything).once
        destroy
      end

      it "should not log the action if quiet is true" do
        expect {
          UserDestroyer.new(admin).destroy(user, destroy_opts.merge(quiet: true))
        }.to_not change { UserHistory.where(action: UserHistory.actions[:delete_user]).count }
      end

      it "triggers a extensibility event" do
        event = DiscourseEvent.track_events { destroy }.last

        expect(event[:event_name]).to eq(:user_destroyed)
        expect(event[:params].first).to eq(user)
      end
    end

    shared_examples "email block list" do
      it "doesn't add email to block list by default" do
        ScreenedEmail.expects(:block).never
        destroy
      end

      it "adds emails to block list if block_email is true" do
        expect {
          UserDestroyer.new(admin).destroy(user, destroy_opts.merge(block_email: true))
        }.to change { ScreenedEmail.count }.by(2)
      end
    end

    context "when user deletes self" do
      subject(:destroy) { UserDestroyer.new(user).destroy(user, destroy_opts) }

      let(:destroy_opts) { { delete_posts: true, context: "/u/username/preferences/account" } }

      include_examples "successfully destroy a user"

      it "logs context in default locale" do
        I18n.locale = :ja
        SiteSetting.default_locale = :de

        destroy
        expect(UserHistory.where(action: UserHistory.actions[:delete_user]).last.context).to eq(
          I18n.with_locale(:de) do
            I18n.t("staff_action_logs.user_delete_self", url: "/u/username/preferences/account")
          end,
        )
      end
    end

    context "when context is missing" do
      it "logs warning message if context is missing" do
        logger = track_log_messages { UserDestroyer.new(admin).destroy(user) }
        expect(logger.warnings).to include(/User destroyed without context from:/)
      end
    end

    context "with a reviewable post" do
      let!(:reviewable) { Fabricate(:reviewable, created_by: user) }

      it "removes the queued post" do
        UserDestroyer.new(admin).destroy(user)
        expect(Reviewable.where(created_by_id: user.id).count).to eq(0)
      end
    end

    context "with a reviewable user" do
      let(:reviewable) { Fabricate(:reviewable, created_by: admin) }

      it "sets the reviewable user as rejected" do
        UserDestroyer.new(admin).destroy(reviewable.target)

        expect(reviewable.reload).to be_rejected
      end
    end

    context "with a directory item record" do
      it "removes the directory item" do
        DirectoryItem.create!(
          user: user,
          period_type: 1,
          likes_received: 0,
          likes_given: 0,
          topics_entered: 0,
          topic_count: 0,
          post_count: 0,
        )
        UserDestroyer.new(admin).destroy(user)
        expect(DirectoryItem.where(user_id: user.id).count).to eq(0)
      end
    end

    context "with a draft" do
      let!(:draft) { Draft.set(user, "test", 0, "test") }

      it "removed the draft" do
        UserDestroyer.new(admin).destroy(user)
        expect(Draft.where(user_id: user.id).count).to eq(0)
      end
    end

    context "when user has posts" do
      let!(:topic_starter) { Fabricate(:user) }
      let!(:topic) { Fabricate(:topic, user: topic_starter) }
      let!(:first_post) { Fabricate(:post, user: topic_starter, topic: topic) }
      let!(:post) { Fabricate(:post, user: user, topic: topic) }

      context "when delete_posts is false" do
        subject(:destroy) { UserDestroyer.new(admin).destroy(user) }

        before do
          user.stubs(:post_count).returns(1)
          user.stubs(:first_post_created_at).returns(Time.zone.now)
        end

        it "should raise the right error" do
          StaffActionLogger.any_instance.expects(:log_user_deletion).never
          expect { destroy }.to raise_error(UserDestroyer::PostsExistError)
          expect(user.reload.id).to be_present
        end
      end

      context "when delete_posts is true" do
        let(:destroy_opts) { { delete_posts: true } }

        context "when staff deletes user" do
          subject(:destroy) { UserDestroyer.new(admin).destroy(user, destroy_opts) }

          include_examples "successfully destroy a user"
          include_examples "email block list"

          it "deletes the posts" do
            destroy
            expect(post.reload.deleted_at).not_to eq(nil)
            expect(post.user_id).to eq(nil)
          end

          it "does not delete topics started by others in which the user has replies" do
            destroy
            expect(topic.reload.deleted_at).to eq(nil)
            expect(topic.user_id).not_to eq(nil)
          end

          it "deletes topics started by the deleted user" do
            spammer_topic = Fabricate(:topic, user: user)
            Fabricate(:post, user: user, topic: spammer_topic)
            destroy
            expect(spammer_topic.reload.deleted_at).not_to eq(nil)
            expect(spammer_topic.user_id).to eq(nil)
          end

          context "when delete_as_spammer is true" do
            before { destroy_opts[:delete_as_spammer] = true }

            it "approves reviewable flags" do
              spammer_post = Fabricate(:post, user: user)
              reviewable = PostActionCreator.inappropriate(admin, spammer_post).reviewable
              expect(reviewable).to be_pending

              destroy

              reviewable.reload
              expect(reviewable).to be_approved
            end

            it "rejects pending posts" do
              post = Fabricate(:post, user: user)
              reviewable =
                Fabricate(
                  :reviewable,
                  type: "ReviewablePost",
                  target_type: "Post",
                  target_id: post.id,
                  created_by: Discourse.system_user,
                  target_created_by: user,
                )

              expect(reviewable).to be_pending

              destroy

              reviewable.reload
              expect(reviewable).to be_rejected
            end
          end
        end

        context "when users deletes self" do
          subject(:destroy) { UserDestroyer.new(user).destroy(user, destroy_opts) }

          include_examples "successfully destroy a user"
          include_examples "email block list"

          it "deletes the posts" do
            destroy
            expect(post.reload.deleted_at).not_to eq(nil)
            expect(post.user_id).to eq(nil)
          end
        end
      end
    end

    context "when user was invited" do
      it "should delete the invite of user" do
        invite = Fabricate(:invite)
        topic_invite = invite.topic_invites.create!(topic: Fabricate(:topic))
        invited_group = invite.invited_groups.create!(group: Fabricate(:group))
        user = Fabricate(:user)
        user.user_emails.create!(email: invite.email)

        UserDestroyer.new(admin).destroy(user)

        expect(Invite.exists?(invite.id)).to eq(false)
        expect(InvitedGroup.exists?(invited_group.id)).to eq(false)
        expect(TopicInvite.exists?(topic_invite.id)).to eq(false)
      end
    end

    context "when user created category" do
      let!(:topic) { Fabricate(:topic, user: user) }
      let!(:first_post) { Fabricate(:post, user: user, topic: topic) }
      let!(:second_post) { Fabricate(:post, user: user, topic: topic) }
      let!(:category) { Fabricate(:category, user: user, topic_id: topic.id) }

      it "changes author of first category post to system user and still deletes second post" do
        UserDestroyer.new(admin).destroy(user, delete_posts: true)

        expect(first_post.reload.deleted_at).to eq(nil)
        expect(first_post.user_id).to eq(Discourse.system_user.id)

        expect(second_post.reload.deleted_at).not_to eq(nil)
        expect(second_post.user_id).to eq(nil)
      end
    end

    context "when user has no posts, but user_stats table has post_count > 0" do
      subject(:destroy) { UserDestroyer.new(user).destroy(user, delete_posts: false) }

      let(:destroy_opts) { {} }

      before do
        # out of sync user_stat data shouldn't break UserDestroyer
        user.user_stat.update_attribute(:post_count, 1)
      end

      include_examples "successfully destroy a user"
    end

    context "when user has deleted posts" do
      let!(:deleted_post) { Fabricate(:post, user: user, deleted_at: 1.hour.ago) }

      it "should mark the user's deleted posts as belonging to a nuked user" do
        expect { UserDestroyer.new(admin).destroy(user) }.to change { User.count }.by(-1)
        expect(deleted_post.reload.user_id).to eq(nil)
      end
    end

    context "when user has no posts" do
      context "when destroy succeeds" do
        subject(:destroy) { UserDestroyer.new(admin).destroy(user) }

        let(:destroy_opts) { {} }

        include_examples "successfully destroy a user"
        include_examples "email block list"
      end

      context "when destroy fails" do
        subject(:destroy) { UserDestroyer.new(admin).destroy(user) }

        it "should not log the action" do
          user.stubs(:destroy).returns(false)
          StaffActionLogger.any_instance.expects(:log_user_deletion).never
          destroy
        end
      end
    end

    context "when user has posts with links" do
      context "with external links" do
        before do
          @post = Fabricate(:post_with_external_links, user: user)
          TopicLink.extract_from(@post)
        end

        it "doesn't add ScreenedUrl records by default" do
          ScreenedUrl.expects(:watch).never
          UserDestroyer.new(admin).destroy(user, delete_posts: true)
        end

        it "adds ScreenedUrl records when :block_urls is true" do
          ScreenedUrl.expects(:watch).with(anything, anything, has_key(:ip_address)).at_least_once
          UserDestroyer.new(admin).destroy(user, delete_posts: true, block_urls: true)
        end
      end

      context "with internal links" do
        before do
          @post = Fabricate(:post_with_external_links, user: user)
          TopicLink.extract_from(@post)
          TopicLink.where(user: user).update_all(internal: true)
        end

        it "doesn't add ScreenedUrl records" do
          ScreenedUrl.expects(:watch).never
          UserDestroyer.new(admin).destroy(user, delete_posts: true, block_urls: true)
        end
      end

      context "with oneboxed links" do
        before do
          @post = Fabricate(:post_with_youtube, user: user)
          TopicLink.extract_from(@post)
        end

        it "doesn't add ScreenedUrl records" do
          ScreenedUrl.expects(:watch).never
          UserDestroyer.new(admin).destroy(user, delete_posts: true, block_urls: true)
        end
      end
    end

    context "with ip address screening" do
      it "doesn't create screened_ip_address records by default" do
        ScreenedIpAddress.expects(:watch).never
        UserDestroyer.new(admin).destroy(user)
      end

      context "when block_ip is true" do
        it "creates a new screened_ip_address record" do
          ScreenedIpAddress.expects(:watch).with(user.ip_address).returns(stub_everything)
          UserDestroyer.new(admin).destroy(user, block_ip: true)
        end

        it "creates two new screened_ip_address records when registration_ip_address is different than last ip_address" do
          user.registration_ip_address = "12.12.12.12"
          ScreenedIpAddress.expects(:watch).with(user.ip_address).returns(stub_everything)
          ScreenedIpAddress
            .expects(:watch)
            .with(user.registration_ip_address)
            .returns(stub_everything)
          UserDestroyer.new(admin).destroy(user, block_ip: true)
        end
      end
    end

    context "when user created a category" do
      let!(:category) { Fabricate(:category_with_definition, user: user) }

      it "assigns the system user to the categories" do
        UserDestroyer.new(admin).destroy(user, delete_posts: true)
        expect(category.reload.user_id).to eq(Discourse.system_user.id)
        expect(category.topic).to be_present
        expect(category.topic.user_id).to eq(Discourse.system_user.id)
      end
    end

    describe "Destroying a user with security key" do
      let!(:security_key) { Fabricate(:user_security_key_with_random_credential, user: user) }

      it "removes the security key" do
        UserDestroyer.new(admin).destroy(user)
        expect(UserSecurityKey.where(user_id: user.id).count).to eq(0)
      end
    end

    describe "Destroying a user with a bookmark" do
      let!(:bookmark) { Fabricate(:bookmark, user: user) }

      it "removes the bookmark" do
        UserDestroyer.new(admin).destroy(user)
        expect(Bookmark.where(user_id: user.id).count).to eq(0)
      end
    end

    context "when user liked things" do
      before do
        @topic = Fabricate(:topic, user: Fabricate(:user))
        @post = Fabricate(:post, user: @topic.user, topic: @topic)
        PostActionCreator.like(user, @post)
      end

      it "should destroy the like" do
        expect { UserDestroyer.new(admin).destroy(user, delete_posts: true) }.to change {
          PostAction.count
        }.by(-1)
        expect(@post.reload.like_count).to eq(0)
      end
    end

    context "when user belongs to groups that grant trust level" do
      let(:group) { Fabricate(:group, grant_trust_level: 4) }

      before { group.add(user) }

      it "can delete the user" do
        d = UserDestroyer.new(admin)
        expect { d.destroy(user) }.to change { User.count }.by(-1)
      end

      it "can delete the user if they have a manual locked trust level and have no email" do
        user.update(manual_locked_trust_level: 3)

        UserEmail.where(user: user).delete_all
        user.reload
        expect { UserDestroyer.new(admin).destroy(user) }.to change { User.count }.by(-1)
      end

      it "can delete the user if they were to fall into another trust level and have no email" do
        g2 = Fabricate(:group, grant_trust_level: 1)
        g2.add(user)

        UserEmail.where(user: user).delete_all
        user.reload
        expect { UserDestroyer.new(admin).destroy(user) }.to change { User.count }.by(-1)
      end
    end

    context "when user has staff action logs" do
      before do
        logger = StaffActionLogger.new(user)
        logger.log_site_setting_change(
          "site_description",
          "Our friendly community",
          "My favourite community",
        )
        logger.log_site_setting_change(
          "site_description",
          "Our friendly community",
          "My favourite community",
          details: "existing details",
        )
      end

      it "should keep the staff action log and add the username" do
        username = user.username
        ids =
          UserHistory.staff_action_records(Discourse.system_user, acting_user: username).map(&:id)
        UserDestroyer.new(admin).destroy(user, delete_posts: true)
        details = UserHistory.where(id: ids).map(&:details)
        expect(details).to contain_exactly(
          "\nuser_id: #{user.id}\nusername: #{username}",
          "existing details\nuser_id: #{user.id}\nusername: #{username}",
        )
      end
    end

    context "when user got an email" do
      let!(:email_log) { Fabricate(:email_log, user: user) }

      it "does not delete the email log" do
        expect { UserDestroyer.new(admin).destroy(user, delete_posts: true) }.to_not change {
          EmailLog.count
        }
      end
    end
  end
end
