require 'plist'

require_relative 'module'
require_relative 'test_command_generator'

module Snapshot
  # Responsible for collecting the generated screenshots and copying them over to the output directory
  class Collector
    # Returns true if it succeeds
    def self.fetch_screenshots(output, dir_name, device_type, launch_arguments_index)
      # Documentation about how this works in the project README
      containing = File.join(TestCommandGenerator.derived_data_path, "Logs", "Test")
      attachments_path = File.join(containing, "Attachments")

      language_folder = File.join(Snapshot.config[:output_directory], dir_name)
      FileUtils.mkdir_p(language_folder)

      # Xcode 9 introduced a new API to take screenshots which allows us
      # to avoid parsing the generated plist file to find the screenshots
      # and instead, we can save them to a known location to use later on.
      if Helper.xcode_at_least?(9)
        return collect_screenshots_for_language_folder(language_folder)
      else
        to_store = attachments(containing)
        matches = output.scan(/snapshot: (.*)/)
      end

      if to_store.count == 0 && matches.count == 0
        return false
      end

      if matches.count != to_store.count
        UI.error("Looks like the number of screenshots (#{to_store.count}) doesn't match the number of names (#{matches.count})")
      end

      matches.each_with_index do |current, index|
        name = current[0]
        filename = to_store[index]

        device_name = device_type.delete(" ")

        components = [launch_arguments_index].delete_if { |a| a.to_s.length == 0 }
        screenshot_name = device_name + "-" + name + "-" + Digest::MD5.hexdigest(components.join("-")) + ".png"
        output_path = File.join(language_folder, screenshot_name)

        from_path = File.join(attachments_path, filename)

        copy(from_path, output_path)
      end
      return true
    end

    # Returns true if it succeeds
    def self.collect_screenshots_for_language_folder(destination)
      # On macOS, the xctrunner is sandboxed and writes screenshots to its
      # container instead of SCREENSHOTS_DIR. Copy them over before collecting.
      copy_screenshots_from_macos_sandbox

      screenshots = Dir["#{SCREENSHOTS_DIR}/*.png"]
      return false if screenshots.empty?
      screenshots.each do |screenshot|
        filename = File.basename(screenshot)
        to_path = File.join(destination, filename)
        copy(screenshot, to_path)
      end
      FileUtils.rm_rf(SCREENSHOTS_DIR)
      return true
    end

    # The macOS UI test runner (xctrunner) runs inside an App Sandbox container.
    # Screenshots written via SnapshotHelper end up in the container's cache
    # directory rather than the shared SCREENSHOTS_DIR that fastlane reads from.
    # This method detects any sandbox screenshots and copies them to SCREENSHOTS_DIR.
    def self.copy_screenshots_from_macos_sandbox
      return unless FastlaneCore::Helper.mac?

      sandbox_base = File.expand_path("~/Library/Containers")
      return unless Dir.exist?(sandbox_base)

      # Find any xctrunner containers that have snapshot screenshots
      Dir.glob(File.join(sandbox_base, "*.xctrunner", "Data", "Library", "Caches", "tools.fastlane", "screenshots")).each do |sandbox_dir|
        sandbox_screenshots = Dir["#{sandbox_dir}/*.png"]
        next if sandbox_screenshots.empty?

        UI.message("Copying #{sandbox_screenshots.length} macOS sandbox screenshot(s) from #{sandbox_dir}")
        FileUtils.mkdir_p(SCREENSHOTS_DIR)
        sandbox_screenshots.each { |f| FileUtils.cp(f, SCREENSHOTS_DIR) }
        # Clean sandbox so stale screenshots don't leak into the next language
        FileUtils.rm(sandbox_screenshots)
      end
    end

    def self.copy(from_path, to_path)
      if FastlaneCore::Globals.verbose?
        UI.success("Copying file '#{from_path}' to '#{to_path}'...")
      else
        UI.success("Copying '#{to_path}'...")
      end
      FileUtils.cp(from_path, to_path)
    end

    def self.attachments(containing)
      UI.message("Collecting screenshots...")
      plist_path = Dir[File.join(containing, "*.plist")].last # we clean the folder before each run
      return attachments_in_file(plist_path)
    end

    def self.attachments_in_file(plist_path)
      UI.verbose("Loading up '#{plist_path}'...")
      report = Plist.parse_xml(plist_path)

      to_store = [] # contains the names of all the attachments we want to use

      report["TestableSummaries"].each do |summary|
        (summary["Tests"] || []).each do |test|
          (test["Subtests"] || []).each do |subtest|
            (subtest["Subtests"] || []).each do |subtest2|
              (subtest2["Subtests"] || []).each do |subtest3|
                (subtest3["ActivitySummaries"] || []).each do |activity|
                  check_activity(activity, to_store)
                end
              end
            end
          end
        end
      end

      UI.message("Found #{to_store.count} screenshots...")
      UI.verbose("Found #{to_store.join(', ')}")
      return to_store
    end

    def self.check_activity(activity, to_store)
      # On iOS, we look for the "Unknown" rotation gesture that signals a snapshot was taken here.
      # On tvOS, we look for "Browser" count.
      # On OSX we look for type `Fn` key on keyboard, it shouldn't change anything for app
      # These are events that are not normally triggered by UI testing, making it easy for us to
      # locate where snapshot() was invoked.
      ios_detected = activity["Title"] == "Set device orientation to Unknown"
      tvos_detected = activity["Title"] == "Get number of matches for: Children matching type Browser"
      osx_detected = activity["Title"] == "Type 'Fn' key (XCUIKeyboardKeySecondaryFn) with no modifiers"
      if ios_detected || tvos_detected || osx_detected
        find_screenshot = find_screenshot(activity)
        to_store << find_screenshot
      end

      (activity["SubActivities"] || []).each do |subactivity|
        check_activity(subactivity, to_store)
      end
    end

    def self.find_screenshot(activity)
      (activity["SubActivities"] || []).each do |subactivity|
        # we are interested in `Synthesize event` part of event in subactivities
        return find_screenshot(subactivity) if subactivity["Title"] == "Synthesize event"
      end

      if activity["Attachments"] && activity["Attachments"].last && activity["Attachments"].last["Filename"]
        return activity["Attachments"].last["Filename"]
      elsif activity["Attachments"]
        return activity["Attachments"].last["FileName"]
      else # Xcode 7.3 has stopped including 'Attachments', so we synthesize the filename manually
        return "Screenshot_#{activity['UUID']}.png"
      end
    end
  end
end
