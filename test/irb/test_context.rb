# frozen_string_literal: false
require 'test/unit'
require 'tempfile'
require 'irb'
require 'rubygems' if defined?(Gem)

module TestIRB
  class TestContext < Test::Unit::TestCase
    class TestInputMethod < ::IRB::InputMethod
      attr_reader :list, :line_no

      def initialize(list = [])
        super("test")
        @line_no = 0
        @list = list
      end

      def gets
        @list[@line_no]&.tap {@line_no += 1}
      end

      def eof?
        @line_no >= @list.size
      end

      def encoding
        Encoding.default_external
      end

      def reset
        @line_no = 0
      end

      def winsize
        [10, 20]
      end
    end

    def setup
      IRB.init_config(nil)
      IRB.conf[:USE_SINGLELINE] = false
      IRB.conf[:VERBOSE] = false
      workspace = IRB::WorkSpace.new(Object.new)
      @context = IRB::Context.new(nil, workspace, TestInputMethod.new)
    end

    def test_last_value
      assert_nil(@context.last_value)
      assert_nil(@context.evaluate('_', 1))
      obj = Object.new
      @context.set_last_value(obj)
      assert_same(obj, @context.last_value)
      assert_same(obj, @context.evaluate('_', 1))
    end

    def test_evaluate_with_exception
      assert_nil(@context.evaluate("$!", 1))
      e = assert_raise_with_message(RuntimeError, 'foo') {
        @context.evaluate("raise 'foo'", 1)
      }
      assert_equal('foo', e.message)
      assert_same(e, @context.evaluate('$!', 1, exception: e))
      e = assert_raise(SyntaxError) {
        @context.evaluate("1,2,3", 1, exception: e)
      }
      assert_match(/\A\(irb\):1:/, e.message)
      assert_not_match(/rescue _\.class/, e.message)
    end

    def test_evaluate_with_encoding_error_without_lineno
      skip if RUBY_ENGINE == 'truffleruby'
      assert_raise_with_message(EncodingError, /invalid symbol/) {
        @context.evaluate(%q[{"\xAE": 1}], 1)
        # The backtrace of this invalid encoding hash doesn't contain lineno.
      }
    end

    def test_evaluate_with_onigmo_warning
      skip if RUBY_ENGINE == 'truffleruby'
      assert_warning("(irb):1: warning: character class has duplicated range: /[aa]/\n") do
        @context.evaluate('/[aa]/', 1)
      end
    end

    def test_eval_input
      verbose, $VERBOSE = $VERBOSE, nil
      input = TestInputMethod.new([
        "raise 'Foo'\n",
        "_\n",
        "0\n",
        "_\n",
      ])
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)
      out, err = capture_output do
        irb.eval_input
      end
      assert_empty err
      assert_pattern_list([:*, /RuntimeError \(.*Foo.*\).*\n/,
                           :*, /#<RuntimeError: Foo>\n/,
                           :*, /0$/,
                           :*, /0$/,
                           /\s*/], out)
    ensure
      $VERBOSE = verbose
    end

    def test_eval_object_without_inspect_method
      verbose, $VERBOSE = $VERBOSE, nil
      input = TestInputMethod.new([
        "BasicObject.new\n",
      ])
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)
      out, err = capture_output do
        irb.eval_input
      end
      assert_empty err
      assert(/\(Object doesn't support #inspect\)\n(=> )?\n/, out)
    ensure
      $VERBOSE = verbose
    end

    def test_default_config
      assert_equal(true, @context.use_colorize?)
    end

    def test_assignment_expression
      input = TestInputMethod.new
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)
      [
        "foo = bar",
        "@foo = bar",
        "$foo = bar",
        "@@foo = bar",
        "::Foo = bar",
        "a::Foo = bar",
        "Foo = bar",
        "foo.bar = 1",
        "foo[1] = bar",
        "foo += bar",
        "foo -= bar",
        "foo ||= bar",
        "foo &&= bar",
        "foo, bar = 1, 2",
        "foo.bar=(1)",
        "foo; foo = bar",
        "foo; foo = bar; ;\n ;",
        "foo\nfoo = bar",
      ].each do |exp|
        assert(
          irb.assignment_expression?(exp),
          "#{exp.inspect}: should be an assignment expression"
        )
      end

      [
        "foo",
        "foo.bar",
        "foo[0]",
        "foo = bar; foo",
        "foo = bar\nfoo",
      ].each do |exp|
        refute(
          irb.assignment_expression?(exp),
          "#{exp.inspect}: should not be an assignment expression"
        )
      end
    end

    def test_echo_on_assignment
      input = TestInputMethod.new([
        "a = 1\n",
        "a\n",
        "a, b = 2, 3\n",
        "a\n",
        "b\n",
        "b = 4\n",
        "_\n"
      ])
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)
      irb.context.return_format = "=> %s\n"

      # The default
      irb.context.echo = true
      irb.context.echo_on_assignment = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> 1\n=> 2\n=> 3\n=> 4\n", out)

      # Everything is output, like before echo_on_assignment was introduced
      input.reset
      irb.context.echo = true
      irb.context.echo_on_assignment = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> 1\n=> 1\n=> [2, 3]\n=> 2\n=> 3\n=> 4\n=> 4\n", out)

      # Nothing is output when echo is false
      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)

      # Nothing is output when echo is false even if echo_on_assignment is true
      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)
    end

    def test_omit_on_assignment
      input = TestInputMethod.new([
        "a = [1] * 100\n",
        "a\n",
      ])
      value = [1] * 100
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)
      irb.context.return_format = "=> %s\n"

      irb.context.echo = true
      irb.context.echo_on_assignment = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> \n#{value.pretty_inspect}", out)

      input.reset
      irb.context.echo = true
      irb.context.echo_on_assignment = :truncate
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> \n#{value.pretty_inspect[0..3]}...\n=> \n#{value.pretty_inspect}", out)

      input.reset
      irb.context.echo = true
      irb.context.echo_on_assignment = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> \n#{value.pretty_inspect}=> \n#{value.pretty_inspect}", out)

      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)

      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = :truncate
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)

      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)
    end

    def test_omit_multiline_on_assignment
      input = TestInputMethod.new([
        "class A; def inspect; ([?* * 1000] * 3).join(%{\\n}); end; end; a = A.new\n",
        "a\n"
      ])
      value = ([?* * 1000] * 3).join(%{\n})
      value_first_line = (?* * 1000).to_s
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)
      irb.context.return_format = "=> %s\n"

      irb.context.echo = true
      irb.context.echo_on_assignment = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> \n#{value}\n", out)
      irb.context.evaluate('A.remove_method(:inspect)', 0)

      input.reset
      irb.context.echo = true
      irb.context.echo_on_assignment = :truncate
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> #{value_first_line[0..(input.winsize.last - 9)]}...\e[0m\n=> \n#{value}\n", out)
      irb.context.evaluate('A.remove_method(:inspect)', 0)

      input.reset
      irb.context.echo = true
      irb.context.echo_on_assignment = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> \n#{value}\n=> \n#{value}\n", out)
      irb.context.evaluate('A.remove_method(:inspect)', 0)

      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)
      irb.context.evaluate('A.remove_method(:inspect)', 0)

      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = :truncate
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)
      irb.context.evaluate('A.remove_method(:inspect)', 0)

      input.reset
      irb.context.echo = false
      irb.context.echo_on_assignment = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("", out)
      irb.context.evaluate('A.remove_method(:inspect)', 0)
    end

    def test_echo_on_assignment_conf
      # Default
      IRB.conf[:ECHO] = nil
      IRB.conf[:ECHO_ON_ASSIGNMENT] = nil
      input = TestInputMethod.new()
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)

      assert(irb.context.echo?, "echo? should be true by default")
      assert_equal(:truncate, irb.context.echo_on_assignment?, "echo_on_assignment? should be :truncate by default")

      # Explicitly set :ECHO to false
      IRB.conf[:ECHO] = false
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)

      refute(irb.context.echo?, "echo? should be false when IRB.conf[:ECHO] is set to false")
      assert_equal(:truncate, irb.context.echo_on_assignment?, "echo_on_assignment? should be :truncate by default")

      # Explicitly set :ECHO_ON_ASSIGNMENT to true
      IRB.conf[:ECHO] = nil
      IRB.conf[:ECHO_ON_ASSIGNMENT] = false
      irb = IRB::Irb.new(IRB::WorkSpace.new(Object.new), input)

      assert(irb.context.echo?, "echo? should be true by default")
      refute(irb.context.echo_on_assignment?, "echo_on_assignment? should be false when IRB.conf[:ECHO_ON_ASSIGNMENT] is set to false")
    end

    def test_multiline_output_on_default_inspector
      main = Object.new
      def main.inspect
        "abc\ndef"
      end
      input = TestInputMethod.new([
        "self"
      ])
      irb = IRB::Irb.new(IRB::WorkSpace.new(main), input)
      irb.context.return_format = "=> %s\n"

      # The default
      irb.context.newline_before_multiline_output = true
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> \nabc\ndef\n",
                   out)

      # No newline before multiline output
      input.reset
      irb.context.newline_before_multiline_output = false
      out, err = capture_io do
        irb.eval_input
      end
      assert_empty err
      assert_equal("=> abc\ndef\n",
                   out)
    end
  end
end
