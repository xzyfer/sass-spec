require 'minitest'
require 'thread'
require 'fileutils'
require 'yaml'
require_relative "interactor"

# Holder to put and run test cases
class SassSpec::Test < Minitest::Test
  def self.create_tests(test_cases, options = {})
    test_cases[0..options[:limit]].each do |test_case|
      define_method("test__#{test_case.name}") do
        runner = SassSpecRunner.new(test_case, options)
        test_case.finalize(runner.run)
        self.assertions += runner.assertions
      end
    end
  end
end

class SassSpecRunner
  include MiniTest::Assertions

  attr_accessor :assertions

  @@interaction_memory = {}

  def initialize(test_case, options = {})
    @assertions = 0
    @test_case = test_case
    @options = options
  end

  def run
    if @test_case.todo? && !@options[:run_todo]
      skip "Skipped #{@test_case.folder}"
    end

    assert_filename_length!(@test_case.input_path)
    assert_filename_length!(@test_case.expected_path)

    assert File.exists?(@test_case.input_path),
      "Input #{@test_case.input_path} file does not exist"

    if @test_case.overwrite?
      overwrite_test!
      return true
    end

    return unless check_annotations!
    return unless handle_missing_output!
    return unless handle_unexpected_error!
    return unless handle_unexpected_pass!
    return unless handle_output_difference!
    return unless handle_unnecessary_todo!

    if @test_case.ignore_warning?
      return true
    elsif @test_case.warning_todo? && !@options[:run_todo]
      skip "Skipped warning check for #{@test_case.folder}"
    else
      return unless handle_expected_error_message!
      return unless handle_unexpected_error_message!
    end

    return true
  end

  private

  ## Failure handlers

  def check_annotations!
    return true unless @options[:check_annotations]

    _output, _, error, _ = @test_case.output
    ignored_warning_impls = @test_case.metadata.warnings_ignored_for

    if ignored_warning_impls.any? && error.length == 0
      message = "No warning issued, but warnings are ignored for #{ignored_warning_impls.join(', ')}"
      choice = interact(:ignore_warning_nonexistant, :fail) do |i|
        i.prompt message

        i.choice('R', "Remove ignored status for #{ignored_warning_impls.join(', ')}") do
          change_options(remove_ignore_warning_for: ignored_warning_impls)
        end

        i.choice('f', "Mark as failed.")
      end

      assert choice != :fail, message
    end

    todo_warning_impls = @test_case.metadata.all_warning_todos
    if todo_warning_impls.any? && error.length == 0
      message = "No warning issued, but warnings are pending for #{todo_warning_impls.join(', ')}"
      choice = interact(:todo_warning_nonexistant, :fail) do |i|
        i.prompt message

        i.choice('R', "Remove TODO status for #{todo_warning_impls.join(', ')}") do
          change_options(remove_warning_todo: todo_warning_impls)
        end

        i.choice('f', "Mark as failed.")
      end

      assert choice != :fail, message
    end

    return true
  end

  def handle_expected_error_message!
    return true unless @test_case.verify_stderr?

    _output, _clean_output, error, _status = @test_case.output

    error_msg = extract_error_message(error)
    expected_error_msg = extract_error_message(@test_case.expected_error)

    return true if expected_error_msg == error_msg
    skip_test_case!("TODO test is failing.") if @test_case.probe_todo?

    interact(:expected_error_different, :fail) do |i|
      i.prompt(error_msg.nil? ? "An error message was expected but wasn't produced." :
                                "Error output doesn't match what was expected.")

      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      if error_msg.nil?
        i.choice('e', "Show expected error.") do
          display_text_block(expected_error_msg)
          i.restart!
        end
      else
        i.choice('d', "Show diff.") do
          require 'diffy'
          display_text_block(
            Diffy::Diff.new("Expected\n#{expected_error_msg}",
                            "Actual\n#{error_msg}").to_s(:color))
          i.restart!
        end
      end

      i.choice('O', "Update expected output and pass test.") do
        overwrite_test!
        return false
      end

      i.choice('V', "Migrate copy of test to pass current version.") do
        migrate_version! || i.restart!
        return false
      end

      i.choice('I', "Migrate copy of test to pass on #{@test_case.impl}.") do
        migrate_impl! || i.restart!
        return false
      end

      unless @test_case.warning_todo?
        i.choice('T', "Mark warning as todo for #{@test_case.impl}.") do
          change_options(add_warning_todo: [@test_case.impl])
          return false
        end
      end

      i.choice('G', "Ignore warning for #{@test_case.impl}.") do
        change_options(add_ignore_warning_for: [@test_case.impl])
        return false
      end

      i.choice('f', "Mark as failed.")

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end

    assert_equal expected_error_msg, error_msg,
      (error_msg.nil? ? "No error message produced" : "Expected did not match error")

    return true
  end

  def handle_unexpected_error_message!
    return true if @test_case.verify_stderr?

    _output, _clean_output, error, _status = @test_case.output

    error_msg = extract_error_message(error)

    return true if error_msg.nil? || error_msg.length == 0

    skip_test_case!("TODO test is failing") if @test_case.probe_todo?

    interact(:unexpected_error_message, :fail) do |i|
      i.prompt "Unexpected output to stderr"

      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      i.choice('e', "Show error.") do
        display_text_block(error)
        i.restart!
      end

      i.choice('O', "Update expected error and pass test.") do
        overwrite_test!
        return false
      end

      i.choice('V', "Migrate copy of test to pass current version.") do
        migrate_version! || i.restart!
        return false
      end

      i.choice('I', "Migrate copy of test to pass on #{@test_case.impl}.") do
        migrate_impl! || i.restart!
        return false
      end

      unless @test_case.warning_todo?
        i.choice('T', "Mark warning as todo for #{@test_case.impl}.") do
          change_options(add_warning_todo: [@test_case.impl])
          return false
        end
      end

      i.choice('G', "Ignore warning for #{@test_case.impl}.") do
        change_options(add_ignore_warning_for: [@test_case.impl])
        return false
      end

      i.choice('f', "Mark as failed.")

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end
    assert false, "Unexpected Error Output: #{error_msg}"
  end

  def handle_output_difference!
    _output, clean_output, _error, _status = @test_case.output

    return true if @test_case.expected == clean_output

    unless @test_case.interactive?
      if @test_case.migrate_version?
        migrate_version!
        return false
      elsif @test_case.migrate_impl?
        migrate_impl!
        return false
      end
    end

    skip_test_case!("TODO test is failing") if @test_case.probe_todo?

    interact(:output_difference, :fail) do |i|
      i.prompt "output does not match expectation"

      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      i.choice('d', "show diff.") do
        require 'diffy'
        display_text_block(
          Diffy::Diff.new("Expected\n" + @test_case.expected,
                          "Actual\n" + clean_output).to_s(:color))
        i.restart!
      end

      i.choice('O', "Update expected output and pass test.") do
        overwrite_test!
        return false
      end

      i.choice('V', "Migrate copy of test to pass current version.") do
        migrate_version! || i.restart!
        return false
      end

      i.choice('I', "Migrate copy of test to pass on #{@test_case.impl}.") do
        migrate_impl! || i.restart!
        return false
      end

      unless @test_case.todo?
        i.choice('T', "Mark spec as todo for #{@test_case.impl}.") do
          change_options(add_todo: [@test_case.impl])
          return false
        end
      end

      i.choice('G', "Ignore test for #{@test_case.impl} FOREVER.") do
        change_options(add_ignore_for: [@test_case.impl])
        return false
      end

      i.choice('f', "Mark as failed.")

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end

    assert_equal @test_case.expected, clean_output, "expected did not match output"
    return true
  end

  def handle_unnecessary_todo!
    output, clean_output, _error, _status = @test_case.output

    return true unless @test_case.todo?
    skip_test_case!(@test_case, "TODO test is passing") unless @test_case.interactive?

    expected_error_msg = extract_error_message(@test_case.expected_error, @options)

    interact(@test_case, :output_difference, :fail) do |i|
      i.prompt "Test is passing but marked as TODO."

      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      unless expected_error_msg.empty?
        i.choice('e', "Show me the expected error.") do
          display_text_block(expected_error_msg)
          i.restart!
        end
      end

      unless output.empty?
        i.choice('o', "Show me the output.") do
          display_text_block(output)
          i.restart!
        end
      end

      i.choice('R', "Remove TODO status for #{@test_case.impl}.") do
        change_options(remove_todo: [@test_case.impl])
        return false
      end

      i.choice('f', "Mark as skipped.") do
        skip_test_case!(@test_case, "TODO test is passing")
      end

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end

    assert_equal @test_case.expected, clean_output, "expected did not match output"
    return true
  end

  def handle_missing_output!
    return true if File.exists?(@test_case.expected_path)

    output, _, error, _ = @test_case.output

    skip_test_case!("TODO test is failing") if @test_case.probe_todo?

    choice = interact(:missing_output, :fail) do |i|
      i.prompt "Expected output file does not exist."

      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      i.choice('e', "Show me the #{error.length > 0 ? 'error' : 'output'} generated.") do
        to_show = error
        to_show = output if to_show.length == 0
        to_show = "No output or error to display." if to_show.length == 0

        display_text_block(to_show)
        i.restart!
      end

      i.choice('D', "Delete test.") do
        if delete_dir!(@test_case.folder)
          return false
        else
          i.restart!
        end
      end

      i.choice('O', "Create it and pass test.") do
        overwrite_test!
        return false
      end

      i.choice('f', "Mark as failed.")

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end
    return true unless choice == :fail

    assert false, "Expected #{@test_case.expected_path} file does not exist"
  end

  def handle_unexpected_pass!
    output, _clean_output, _error, status = @test_case.output
    return true if status != 0

    if @test_case.interactive?
      return true if !@test_case.should_fail?
    else
      return true if !@test_case.should_fail?

      if @test_case.migrate_version?
        migrate_version!
        return false
      elsif @test_case.migrate_impl?
        migrate_impl!
        return false
      end
    end

    skip_test_case!("TODO test is failing") if @test_case.probe_todo?

    choice = interact(:unexpected_pass, :fail) do |i|
      i.prompt "A failure was expected but it compiled instead."
      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      i.choice('e', "Show me the expected error.") do
        display_text_block(File.read(@test_case.error_path))
        i.restart!
      end

      i.choice('o', "Show me the output.") do
        display_text_block(output)
        i.restart!
      end

      i.choice('O', "Update test and mark it passing.") do
        overwrite_test!
      end

      i.choice('V', "Migrate copy of test to pass current version.") do
        migrate_version! || i.restart!
        return false
      end

      i.choice('I', "Migrate copy of test to pass on #{@test_case.impl}.") do
        migrate_impl! || i.restart!
        return false
      end

      unless @test_case.todo?
        i.choice('T', "Mark spec as todo for #{@test_case.impl}.") do
          change_options(add_todo: [@test_case.impl])
          return false
        end
      end

      i.choice('f', "Fail test and continue.")

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end
    return false unless choice == :fail

    # XXX Ruby returns 65 etc. SassC returns 1
    refute_equal status, 0, "Test case should fail, but it did not"
    return true
  end

  def handle_unexpected_error!
    _output, _clean_output, error, status = @test_case.output
    return true if status == 0 || @test_case.should_fail?

    unless @test_case.interactive?
      if @test_case.migrate_version?
        migrate_version!
        return false
      elsif @test_case.migrate_impl?
        migrate_impl!
        return false
      end
    end

    skip_test_case!("TODO test is failing") if @test_case.probe_todo?

    choice = interact(:unexpected_error, :fail) do |i|
      i.prompt "An unexpected compiler error was encountered."
      i.choice('i', "Show me the input.") do
        display_text_block(File.read(@test_case.input_path))
        i.restart!
      end

      i.choice('e', "Show me the error.") do
        display_text_block(error)
        i.restart!
      end

      i.choice('o', "Show me the expected output.") do
        display_text_block(@test_case.expected)
        i.restart!
      end

      i.choice('O', "Update test to expect this failure.") do
        overwrite_test!
      end

      i.choice('V', "Migrate copy of test to pass current version.") do
        migrate_version! || i.restart!
        return false
      end

      i.choice('I', "Migrate copy of test to pass on #{@test_case.impl}.") do
        migrate_impl! || i.restart!
        return false
      end

      unless @test_case.todo?
        i.choice('T', "Mark spec as todo for #{@test_case.impl}.") do
          change_options(add_todo: [@test_case.impl])
          return false
        end
      end

      i.choice('G', "Ignore test for #{@test_case.impl} FOREVER.") do
        change_options(add_ignore_for: [@test_case.impl])
      end

      i.choice('f', "Fail test and continue.")

      i.choice('X', "Exit testing.") do
        raise Interrupt
      end
    end
    return false unless choice == :fail

    assert_equal 0, status,
      "Command `#{@options[:engine_adapter]}` did not complete:\n\n#{error}"
    return true
  end

  ## Interaction utilities

  # If the runner is running in interactive mode, runs the interaction defined
  # in the block and returns the result. Otherwise, just returns the default
  # value.
  def interact(prompt_id, default, dir = @test_case.folder, &block)
    if @test_case.interactive?
      relative_path = Pathname.new(dir).relative_path_from(Pathname.new(Dir.pwd))
      print "\nIn test case: #{relative_path}"
      return SassSpec::Interactor.interact_with_memory(@@interaction_memory, prompt_id, &block)
    else
      return default
    end
  end

  # Deletes a directory. In interactive mode, prompts the user and returns
  # `false` if they decide not to delete the directory.
  def delete_dir!(dir)
    result = interact(:delete_test, :proceed) do |i|
      files = Dir.glob(File.join(dir, "**", "*"))
      i.prompt("The following files will be removed:\n  * " + files.join("\n  * "))
      i.choice('D', "Delete them.") do
        FileUtils.rm_rf(@test_case.folder)
      end
      i.choice('x', "I changed my mind.") do
      end
    end
    result == :proceed
  end

  # Creates a copy of the test test that's compatible with the current version.
  #
  # Marks the original as only being valid until the version before the current
  # version. Marks the copy as being valid starting with the current version.
  # Updates the copy to expect current actual results.
  def migrate_version!
    current_version = @options[:language_version]
    current_version_index = SassSpec::LANGUAGE_VERSIONS.index(current_version)
    if current_version_index == 0
      puts "Cannot migrate test. There's no version earlier than #{current_version}."
      return false
    end

    start_version_index = SassSpec::LANGUAGE_VERSIONS.index(
      @test_case.metadata.start_version.to_s)

    if start_version_index >= current_version_index
      puts "Cannot migrate test. Test does not apply to an earlier version."
      return false
    end

    previous_version = SassSpec::LANGUAGE_VERSIONS[current_version_index - 1]

    new_folder = @test_case.folder + "-#{current_version}"

    if File.exist?(new_folder)
      choice = interact(:migrate_over_existing, :abort) do |i|
        i.prompt("Target folder '#{new_folder}' already exists.")

        i.choice('x', "Don't migrate the test.") do
          return false
        end

        i.choice('O', "Remove it.") do
          unless delete_dir!(new_folder)
            i.restart!
          end
        end
      end

      if choice == :abort
        puts "Cannot migrate test. #{new_folder} already exists."
        return false
      end
    end

    FileUtils.cp_r @test_case.folder, new_folder

    new_test_case = SassSpec::TestCase.new(new_folder, @options)
    change_options(end_version: previous_version)
    change_options(new_test_case.options_path, start_version: current_version)

    overwrite_test!(new_test_case)

    return true
  end

  # Creates a copy of a test that's compatible with the current implementation.
  #
  # Marks the original as ignored for the current implementation. Marks the copy
  # as being valid only for the current version. Updates the copy to expect
  # current actual results.
  def migrate_impl!
    new_folder = @test_case.folder + "-#{@test_case.impl}"

    if File.exist?(new_folder)
      choice = interact(:migrate_over_existing, :abort) do |i|
        i.prompt("Target folder '#{new_folder}' already exists.")

        i.choice('x', "Don't migrate the test.") do
          return false
        end

        i.choice('O', "Remove it.") do
          unless delete_dir!(new_folder)
            i.restart!
          end
        end
      end

      if choice == :abort
        puts "Cannot migrate test. #{new_folder} already exists."
        return false
      end
    end

    FileUtils.cp_r @test_case.folder, new_folder

    new_test_case = SassSpec::TestCase.new(new_folder, @options)
    change_options(add_ignore_for: [@test_case.impl])
    change_options(new_test_case.options_path, only_on: [@test_case.impl])

    overwrite_test!(new_test_case)

    return true
  end

  ## Other utilities

  def skip_test_case!(reason = nil)
    msg = "Skipped #{@test_case.folder}" 
    if reason
      msg << ": #{reason}"
    else
      msg << "."
    end
    skip msg
  end

  ANSI_ESCAPES = /[\u001b\u009b][\[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/
  def display_text_block(text)
    delim = "*" * text.gsub(ANSI_ESCAPES, '').lines.map{|l| l.rstrip.size}.max

    puts delim
    puts text
    puts delim
  end

  def overwrite_test!(test_case = @test_case)
    output, _, error, status = @test_case.output

    if status != 0
      File.open(@test_case.status_path, "w+", :binmode => true) do |f|
        f.write(status)
      end
    elsif (File.file?(@test_case.status_path))
      File.unlink(@test_case.status_path)
    end

    if error.length > 0
      File.open(@test_case.error_path, "w+", :binmode => true) do |f|
        f.write(error)
      end
    elsif (File.file?(@test_case.error_path))
      File.unlink(@test_case.error_path)
    end

    File.open(@test_case.expected_path, "w+", :binmode => true) do |f|
      f.write(output)
    end
  end

  def change_options(file_or_new_options, new_options = nil)
    if new_options
      options_file = file_or_new_options
    else
      options_file = @test_case.options_path
      new_options = file_or_new_options
    end

    existing_options = if File.exist?(options_file)
                         YAML.load_file(options_file)
                       else
                         {}
                       end

    existing_options = SassSpec::TestCaseMetadata.merge_options(existing_options, new_options)

    if existing_options.any?
      File.open(options_file, "w") do |f|
        f.write(existing_options.to_yaml)
      end
    else
      File.unlink(options_file) if File.exist?(options_file)
    end
  end

  GEMFILE_PREFIX_LENGTH = 68
  # When running sass-spec as a gem from github very long filenames can cause
  # installation issues. This checks that the paths in use will work.
  def assert_filename_length!(filename)
    name = relative_name = filename.to_s.sub(File.expand_path(@options[:spec_directory]), "")
    assert false, "Filename #{name} must no more than #{256 - GEMFILE_PREFIX_LENGTH} characters long" if name.size > (256 - GEMFILE_PREFIX_LENGTH)

    if name.size <= 100 then
      prefix = ""
    else
      parts = name.split(/\//)
      newname = parts.pop
      nxt = ""

      loop do
        nxt = parts.pop
        break if newname.size + 1 + nxt.size > 100
        newname = nxt + "/" + newname
      end

      prefix = (parts + [nxt]).join "/"
      name = newname

      assert false, "base name (#{name}) of #{relative_name} must no more than 100 characters long" if name.size > 100
      assert false, "prefix (#{prefix}) of #{relative_name} must no more than #{155 - GEMFILE_PREFIX_LENGTH} characters long" if prefix.size > (155 - GEMFILE_PREFIX_LENGTH)
    end
    return nil
  end

  def extract_error_message(error)
    # We want to make sure dart-sass continues to generate correct stack traces
    # and text highlights, so we check its full error messages.
    if @options[:engine_adapter].describe == 'dart-sass'
      return clean_debug_path(error.rstrip)
    end

    error_message = ""
    consume_next_line = false
    error.each_line do |line|
      if consume_next_line
        next if line.strip == ""
        error_message += line
        break
      end
      if (line =~ /DEPRECATION WARNING/)
        if line.rstrip.end_with?(":")
          error_message = line.rstrip + "\n"
          consume_next_line = true
          next
        else
          error_message = line
          break
        end
      end
      if (line =~ /Error:/)
        error_message = line
        break
      end
    end
    clean_debug_path(error_message.rstrip)
  end

  def clean_debug_path(error)
    spec_dir = File.expand_path(@options[:spec_directory])
    url = spec_dir.gsub(/\\/, '\/')
    error.gsub(/^.*?(input.scss:\d+ DEBUG:)/, '\1')
         .gsub(/\/+/, "/")
         .gsub(/^#{Regexp.quote(url)}\//, "/sass/sass-spec/")
         .gsub(/^#{Regexp.quote(spec_dir)}\//, "/sass/sass-spec/")
         .gsub(/(?:\/todo_|_todo\/)/, "/")
         .gsub(/\/libsass\-[a-z]+\-tests\//, "/")
         .gsub(/\/libsass\-[a-z]+\-issues/, "/libsass-issues")
         .strip
  end
end
