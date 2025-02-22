# frozen_string_literal: true

class Notification < ActiveRecord::Base
  belongs_to :user
  belongs_to :topic

  validates_presence_of :data
  validates_presence_of :notification_type

  scope :unread, lambda { where(read: false) }
  scope :recent, lambda { |n = nil| n ||= 10; order('notifications.created_at desc').limit(n) }
  scope :visible , lambda { joins('LEFT JOIN topics ON notifications.topic_id = topics.id')
    .where('topics.id IS NULL OR topics.deleted_at IS NULL') }

  scope :filter_by_display_username_and_type, ->(username, notification_type) {
    where("data::json ->> 'display_username' = ?", username)
      .where(notification_type: notification_type)
      .order(created_at: :desc)
  }

  attr_accessor :skip_send_email

  after_commit :send_email, on: :create
  after_commit :refresh_notification_count, on: [:create, :update, :destroy]

  after_commit(on: :create) do
    DiscourseEvent.trigger(:notification_created, self)
  end

  def self.ensure_consistency!
    DB.exec(<<~SQL, Notification.types[:private_message])
      DELETE
        FROM notifications n
       WHERE notification_type = ?
         AND NOT EXISTS (
            SELECT 1
              FROM posts p
              JOIN topics t ON t.id = p.topic_id
             WHERE p.deleted_at IS NULL
               AND t.deleted_at IS NULL
               AND p.post_number = n.post_number
               AND t.id = n.topic_id
          )
    SQL
  end

  def self.types
    @types ||= Enum.new(mentioned: 1,
                        replied: 2,
                        quoted: 3,
                        edited: 4,
                        liked: 5,
                        private_message: 6,
                        invited_to_private_message: 7,
                        invitee_accepted: 8,
                        posted: 9,
                        moved_post: 10,
                        linked: 11,
                        granted_badge: 12,
                        invited_to_topic: 13,
                        custom: 14,
                        group_mentioned: 15,
                        group_message_summary: 16,
                        watching_first_post: 17,
                        topic_reminder: 18,
                        liked_consolidated: 19,
                        post_approved: 20,
                        code_review_commit_approved: 21,
                        membership_request_accepted: 22
                       )
  end

  def self.mark_posts_read(user, topic_id, post_numbers)
    Notification
      .where(
        user_id: user.id,
        topic_id: topic_id,
        post_number: post_numbers,
        read: false
      )
      .update_all(read: true)
  end

  def self.read(user, notification_ids)
    Notification
      .where(
        id: notification_ids,
        user_id: user.id,
        read: false
      )
      .update_all(read: true)
  end

  def self.interesting_after(min_date)
    result = where("created_at > ?", min_date)
      .includes(:topic)
      .visible
      .unread
      .limit(20)
      .order("CASE WHEN notification_type = #{Notification.types[:replied]} THEN 1
                           WHEN notification_type = #{Notification.types[:mentioned]} THEN 2
                           ELSE 3
                      END, created_at DESC").to_a

    # Remove any duplicates by type and topic
    if result.present?
      seen = {}
      to_remove = Set.new

      result.each do |r|
        seen[r.notification_type] ||= Set.new
        if seen[r.notification_type].include?(r.topic_id)
          to_remove << r.id
        else
          seen[r.notification_type] << r.topic_id
        end
      end
      result.reject! { |r| to_remove.include?(r.id) }
    end

    result
  end

  # Clean up any notifications the user can no longer see. For example, if a topic was previously
  # public then turns private.
  def self.remove_for(user_id, topic_id)
    Notification.where(user_id: user_id, topic_id: topic_id).delete_all
  end

  # Be wary of calling this frequently. O(n) JSON parsing can suck.
  def data_hash
    @data_hash ||= begin
      return {} if data.blank?

      parsed = JSON.parse(data)
      return {} if parsed.blank?

      parsed.with_indifferent_access
    end
  end

  def url
    topic.relative_url(post_number) if topic.present?
  end

  def post
    return if topic_id.blank? || post_number.blank?
    Post.find_by(topic_id: topic_id, post_number: post_number)
  end

  def self.recent_report(user, count = nil)
    return unless user && user.user_option

    count ||= 10
    notifications = user.notifications
      .visible
      .recent(count)
      .includes(:topic)

    if user.user_option.like_notification_frequency == UserOption.like_notification_frequency_type[:never]
      [
        Notification.types[:liked],
        Notification.types[:liked_consolidated]
      ].each do |notification_type|
        notifications = notifications.where(
          'notification_type <> ?', notification_type
        )
      end
    end

    notifications = notifications.to_a

    if notifications.present?

      ids = DB.query_single(<<~SQL, count.to_i)
         SELECT n.id FROM notifications n
         WHERE
           n.notification_type = 6 AND
           n.user_id = #{user.id.to_i} AND
           NOT read
        ORDER BY n.id ASC
        LIMIT ?
      SQL

      if ids.length > 0
        notifications += user
          .notifications
          .order('notifications.created_at DESC')
          .where(id: ids)
          .joins(:topic)
          .limit(count)
      end

      notifications.uniq(&:id).sort do |x, y|
        if x.unread_pm? && !y.unread_pm?
          -1
        elsif y.unread_pm? && !x.unread_pm?
          1
        else
          y.created_at <=> x.created_at
        end
      end.take(count)
    else
      []
    end

  end

  def unread_pm?
    Notification.types[:private_message] == self.notification_type && !read
  end

  def post_id
    Post.where(topic: topic_id, post_number: post_number).pluck_first(:id)
  end

  protected

  def refresh_notification_count
    if user_id
      User.find_by(id: user_id)&.publish_notifications_state
    end
  end

  def send_email
    NotificationEmailer.process_notification(self) if !skip_send_email
  end

end

# == Schema Information
#
# Table name: notifications
#
#  id                :integer          not null, primary key
#  notification_type :integer          not null
#  user_id           :integer          not null
#  data              :string(1000)     not null
#  read              :boolean          default(FALSE), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  topic_id          :integer
#  post_number       :integer
#  post_action_id    :integer
#
# Indexes
#
#  idx_notifications_speedup_unread_count                       (user_id,notification_type) WHERE (NOT read)
#  index_notifications_on_post_action_id                        (post_action_id)
#  index_notifications_on_read_or_n_type                        (user_id,id DESC,read,topic_id) UNIQUE WHERE (read OR (notification_type <> 6))
#  index_notifications_on_user_id_and_created_at                (user_id,created_at)
#  index_notifications_on_user_id_and_id                        (user_id,id) UNIQUE WHERE ((notification_type = 6) AND (NOT read))
#  index_notifications_on_user_id_and_topic_id_and_post_number  (user_id,topic_id,post_number)
#
