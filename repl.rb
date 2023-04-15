require 'irb'
require 'rbs'
require 'rbs/cli'
require 'ripper'

module ToyCompletion
  def self.sexp_of(incomplete_code)
    tokens = Ripper.lex incomplete_code
    closing_tokens = []
    tokens.filter_map do |_pos, event, tok, state|
      case event
      when :on_lparen
        closing_tokens << ')'
      when :on_lbrace
        closing_tokens << '}'
      when :on_lbracket
        closing_tokens << ']'
      when :on_rparen, :on_rbrace, :on_rbracket
        closing_tokens.pop
      when :on_kw
        case tok
        when 'def', 'do'
          closing_tokens << 'end'
        when 'while', 'if', 'unless', 'until'
          closing_tokens << 'end' unless state.allbits? Ripper::EXPR_LABEL
        when 'end'
          closing_tokens.pop
        end
      end
    end
    Ripper.sexp(incomplete_code + "dummy_method_name\n" + closing_tokens.reverse.join("\n"))
  end

  def self.completion_receiver_types(incomplete_code, binding)
    lines = incomplete_code.lines
    pos = [lines.size, lines.last[/.*\./]&.bytesize]
    exp = sexp_of(incomplete_code)
    return [] unless exp
    receiver = find_method_call_receiver_node(exp, pos)
    return [] unless receiver
    evaluate_by_rbs_type(receiver, [binding.eval('self').class], binding)
  end

  def self.find_method_call_receiver_node(exp, pos)
    if exp in [:call, receiver, [:@period, '.', ], [:@ident, _, ^pos]]
      return receiver
    end
    exp.grep(Array).each do |a|
      res = find_method_call_receiver_node a, pos
      return res if res
    end
    nil
  end

  def self.evaluate_by_rbs_type(exp, self_klasses, binding)
    case exp
    in [:var_ref, [:@ident, name,]]
      [(binding.local_variable_get(name).class rescue Object)]
    in [:var_ref, [:@const, name,]]
      [(Object.const_get(name).class rescue Object)]
    in [:vcall | :fcall, [:@ident, method,]]
      method_response_types self_klasses, method.to_sym
    in [:call, receiver, _, [:@ident, method,]]
      method_response_types evaluate_by_rbs_type(receiver, self_klasses, binding), method.to_sym
    in [:method_add_arg | :method_add_block, call, _]
      evaluate_by_rbs_type call, self_klasses, binding
    in [:var_ref, [:@kw, 'true',]]
      [TrueClass]
    in [:var_ref, [:@kw, 'false',]]
      [FalseClass]
    in [:var_ref, [:@kw, 'nil',]]
      [NilClass]
    in [:@int,]
      [Integer]
    in [:@float,]
      [Float]
    in [:array,]
      [Array]
    in [:hash,]
      [Hash]
    in [:symbol_literal,]
      [Symbol]
    in [:string_literal,]
      [String]
    in [:regexp_literal,]
      [Regexp]
    else
      [Object]
    end
  end

  def self.method_response_types(klasses, name)
    klasses.flat_map do |klass|
      method = rbs_search_method(klass, name, false)
      next [] unless method
      method.method_types.filter_map do |type|
        return_type = type.type.return_type
        case return_type
        when RBS::Types::Bases::Self
          klass
        when RBS::Types::ClassInstance
          Object.const_get(return_type.name.name) rescue nil
        end
      end
    end.uniq
  end

  def self.rbs_builder
    @rbs_builder ||= RBS::DefinitionBuilder.new(
      env: RBS::Environment.from_loader(RBS::CLI::LibraryOptions.new.loader).resolve_type_names
    )
  end

  def self.rbs_search_method(klass, method_name, singleton)
    klass.ancestors.each do |ancestor|
      name = ancestor.name
      next unless name
      type_name = RBS::TypeName(name).absolute!
      definition = (singleton ? rbs_builder.build_singleton(type_name) : rbs_builder.build_instance(type_name)) rescue nil
      method = definition&.methods&.[](method_name)
      return method if method
    end
    nil
  end
end

def (IRB::InputCompletor::CompletionProc).call(target, preposing, postposing)
  bind = IRB.conf[:MAIN_CONTEXT].workspace.binding
  lvars_code = [bind.local_variables, 'nil'].join('=')
  incomplete_code = lvars_code + ";\n" + preposing + target
  /(?<prefix>.*\.)?(?<method_name>[^.]*)$/ =~ target
  klasses = ToyCompletion.completion_receiver_types(incomplete_code, bind)
  candidates = klasses.flat_map(&:instance_methods).uniq.select do |name|
    name.start_with? method_name
  end
  candidates.map { "#{prefix}#{_1}" }
rescue
  []
end

IRB.start
