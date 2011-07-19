module Mirah
  module JVM
    module Compiler
      class JVMBytecode < Base
        java_import java.lang.System
        java_import java.io.PrintStream
        include Mirah::JVM::MethodLookup
        Types = Mirah::JVM::Types

        class << self
          attr_accessor :verbose

          def log(message)
            puts "* [#{name}] #{message}" if JVMBytecode.verbose
          end

          def classname_from_filename(filename)
            basename = File.basename(filename).sub(/\.(duby|mirah)$/, '')
            basename.split(/_/).map{|x| x[0...1].upcase + x[1..-1]}.join
          end
        end

        module JVMLogger
          def log(message); JVMBytecode.log(message); end
        end

        class ImplicitSelf
          attr_reader :inferred_type

          def initialize(type, scope)
            @inferred_type = type
            @scope = scope
          end

          def compile(compiler, expression)
            compiler.compile_self(@scope) if expression
          end
        end

        def initialize(scoper)
          super
          @jump_scope = []
        end

        def file_builder(filename)
          builder = BiteScript::FileBuilder.new(filename)
          builder.to_widen do |a, b|
            a = AST.type_factory.get_type(a)
            b = AST.type_factory.get_type(b)
            a_ancestors = []
            while a
              a_ancestors << a.name
              a = a.superclass
            end
            b_ancestors = []
            while b
              b_ancestors << b.name
              b = b.superclass
            end
            (a_ancestors & b_ancestors)[0]
          end
          AST.type_factory.define_types(builder)
          builder
        end

        def output_type
          "classes"
        end

        def push_jump_scope(node)
          raise "Not a node" unless Mirah::AST::Node === node
          begin
            @jump_scope << node
            yield
          ensure
            @jump_scope.pop
          end
        end

        def find_ensures(before)
          found = []
          @jump_scope.reverse_each do |scope|
            if Mirah::AST::Ensure === scope
              found << scope
            end
            break if before === scope
          end
          found
        end

        def begin_main
          # declare argv variable
          @method.local('argv', AST.type(nil, 'string', true))
        end

        def finish_main
          @method.returnvoid
        end

        def prepare_binding(node)
          scope = introduced_scope(node)
          if scope.has_binding?
            type = scope.binding_type
            @binding = @bindings[type]
            @method.new type
            @method.dup
            @method.invokespecial type, "<init>", [@method.void]
            if node.respond_to? :arguments
              node.arguments.args.each do |param|
                name = param.name.identifier
                param_type = inferred_type(param)
                if scope.captured?(param.name.identifier)
                  @method.dup
                  type.load(@method, @method.local(name, param_type))
                  @method.putfield(type, name, param_type)
                end
              end
            end
            type.store(@method, @method.local('$binding', type))
          end
          begin
            yield
          ensure
            if scope.has_binding?
              @binding.stop
              @binding = nil
            end
          end
        end

        def visitMethodDefinition(node, expression)
          push_jump_scope(node) do
            base_define_method(node, true) do |method, arg_types|
              return if @class.interface?
              is_static = self.static || node.kind_of?(StaticMethodDefinition)

              log "Starting new #{is_static ? 'static ' : ''}method #{node.name.identifier}(#{arg_types})"
              args = node.arguments.args
              method_body(method, args, node, inferred_type(node))
              log "Method #{node.name.identifier}(#{arg_types}) complete!"
            end
          end
        end

        def define_optarg_chain(name, arg, return_type,
          args_for_opt, arg_types_for_opt)
          # declare all args so they get their values
          @method.aload(0) unless @static
          args_for_opt.each do |req_arg|
            inferred_type(req_arg).load(@method, @method.local(req_arg.name.identifier, inferred_type(req_arg)))
          end
          visit(arg.value, true)

          # invoke the next one in the chain
          if @static
            @method.invokestatic(@class, name.to_s, [return_type] + arg_types_for_opt + [inferred_type(arg)])
          else
            @method.invokevirtual(@class, name.to_s, [return_type] + arg_types_for_opt + [inferred_type(arg)])
          end

          return_type.return(@method)
        end

        def visitConstructorDefinition(node, expression)
          push_jump_scope(node) do
            super(node, true) do |method, args|
              method_body(method, args, node, Types::Void) do
                method.aload 0
                if node.delegate_args
                  if node.calls_super
                    delegate_class = @type.superclass
                  else
                    delegate_class = @type
                  end
                  delegate_types = node.delegate_args.map do |arg|
                    inferred_type(arg)
                  end
                  constructor = delegate_class.constructor(*delegate_types)
                  node.delegate_args.each do |arg|
                    visit(arg, true)
                  end
                  method.invokespecial(
                  delegate_class, "<init>",
                  [@method.void, *constructor.argument_types])
                else
                  method.invokespecial @class.superclass, "<init>", [@method.void]
                end
              end
            end
          end
        end

        def method_body(method, args, node, return_type)
          body = node.body
          with(:method => method,
          :declared_locals => {}) do

            method.start

            scope = introduced_scope(node)

            # declare all args so they get their values
            if args
              args.each {|arg| declare_local(scope, arg.name.identifier, inferred_type(arg))}
            end
            declare_locals(scope)

            yield if block_given?

            prepare_binding(node) do
              expression = return_type != Types::Void
              visit(body, expression) if body
            end

            return_type.return(@method)

            @method.stop
          end
        end

        def visitClosureDefinition(class_def, expression)
          compiler = ClosureCompiler.new(@file, @type, self)
          compiler.visitClassDefinition(class_def, expression)
        end

        def visitIf(iff, expression)
          elselabel = @method.label
          donelabel = @method.label

          # this is ugly...need a better way to abstract the idea of compiling a
          # conditional branch while still fitting into JVM opcodes
          predicate = iff.condition
          if iff.body || expression
            jump_if_not(predicate, elselabel)

            if iff.body
              visit(iff.body, expression)
            elsif expression
              inferred_type(iff).init_value(@method)
            end

            @method.goto(donelabel)
          else
            jump_if(predicate, donelabel)
          end

          elselabel.set!

          if iff.elseBody
            visit(iff.elseBody, expression)
          elsif expression
            inferred_type(iff).init_value(@method)
          end

          donelabel.set!
        end

        def visitLoop(loop, expression)
          push_jump_scope(loop) do
            with(:break_label => @method.label,
                 :redo_label => @method.label,
                 :next_label => @method.label) do
              predicate = loop.condition

              visit(loop.init, false)

              pre_label = @redo_label

              unless loop.skipFirstCheck
                @next_label.set! unless loop.post_size > 0
                if loop.negative
                  # if condition, exit
                  jump_if(predicate, @break_label)
                else
                  # if not condition, exit
                  jump_if_not(predicate, @break_label)
                end
              end

              if loop.pre_size > 0
                pre_label = method.label
                pre_label.set!
                visit(loop.pre, false)
              end


              @redo_label.set!
              visit(loop.body, false) if loop.body

              if loop.skipFirstCheck || loop.post_size > 0
                @method.goto(@next_label)
              else
                @next_label.set!
                visit(loop.post, false)
                if loop.negative
                  # if not condition, continue
                  jump_if_not(predicate, pre_label)
                else
                  # if condition, continue
                  jump_if(predicate, pre_label)
                end
              end

              @break_label.set!

              # loops always evaluate to null
              @method.aconst_null if expression
            end
          end
        end

        def visitBreak(node, expression)
          error("break outside of loop", node) unless @break_label
          handle_ensures(find_ensures(Mirah::AST::Loop))
          set_position node.position
          @method.goto(@break_label)
        end

        def visitNext(node, expression)
          error("next outside of loop", node) unless @next_label
          handle_ensures(find_ensures(Mirah::AST::Loop))
          set_position node.position
          @method.goto(@next_label)
        end

        def visitRedo(node, expression)
          error("redo outside of loop", node) unless @redo_label
          handle_ensures(find_ensures(Mirah::AST::Loop))
          set_position node.position
          @method.goto(@redo_label)
        end

        def jump_if(predicate, target)
          unless inferred_type(predicate) == Types::Boolean
            raise "Expected boolean, found #{inferred_type(predicate)}"
          end
          if Mirah::AST::Call === predicate
            method = extract_method(predicate)
            if method.respond_to? :jump_if
              method.jump_if(self, predicate, target)
              return
            end
          end
          visit(predicate, true)
          @method.ifne(target)
        end

        def jump_if_not(predicate, target)
          unless inferred_type(predicate) == Types::Boolean
            raise "Expected boolean, found #{inferred_type(predicate)}"
          end
          if Mirah::AST::Call === predicate
            method = extract_method(predicate)
            if method.respond_to? :jump_if_not
              method.jump_if_not(self, predicate, target)
              return
            end
          end
          visit(predicate, true)
          @method.ifeq(target)
        end

        def extract_method(call)
          target = inferred_type(call)(target)!
          params = call.parameters.map do |param|
            inferred_type(param)!
          end
          target.get_method(call.name.identifier, params)
        end

        def visitCall(call, expression)
          method = extract_method(call)
          if method
            method.call(self, call, expression)
          else
            raise "Missing method #{target}.#{call.name.identifier}(#{params.join ', '})"
          end
        end

        def visitFunctionalCall(fcall, expression)
          type = get_scope(fcall).self_type
          type = type.meta if (@static && type == @type)
          fcall.target = ImplicitSelf.new(type, get_scope(fcall))

          params = fcall.parameters.map do |param|
            inferred_type(param)
          end
          method = type.get_method(fcall.name.identifier, params)
          unless method
            target = static ? @class.name : 'self'

            raise NameError, "No method %s.%s(%s)" %
            [target, fcall.name.identifier, params.join(', ')]
          end
          method.call(self, fcall, expression)
        end

        def visitSuper(sup, expression)
          type = @type.superclass
          sup.target = ImplicitSelf.new(type, get_scope(sup))

          params = sup.parameters.map do |param|
            inferred_type(param)
          end
          method = type.get_method(sup.name, params)
          unless method
            raise NameError, "No method %s.%s(%s)" %
            [type, sup.name, params.join(', ')]
          end
          method.call_special(self, sup, expression)
        end

        def visitCast(fcall, expression)
          # casting operation, not a call
          castee = fcall.parameters(0)

          # TODO move errors to inference phase
          source_type_name = inferred_type(castee)
          target_type_name = inferred_type(fcall).name
          if inferred_type(castee).primitive?
            if inferred_type(fcall).primitive?
              if source_type_name == 'boolean' && target_type_name != "boolean"
                raise TypeError.new "not a boolean type: #{inferred_type(castee)}"
              end
              # ok
              primitive = true
            else
              raise TypeError.new "Cannot cast #{inferred_type(castee)} to #{inferred_type(fcall)}: not a reference type."
            end
          elsif inferred_type(fcall).primitive?
            raise TypeError.new "not a primitive type: #{inferred_type(castee)}"
          else
            # ok
            primitive = false
          end

          visit(castee, expression)
          if expression
            if primitive
              source_type_name = 'int' if %w[byte short char].include? source_type_name
              if (source_type_name != 'int') && (%w[byte short char].include? target_type_name)
                target_type_name = 'int'
              end

              if source_type_name != target_type_name
                if RUBY_VERSION == "1.9"
                  @method.send "#{source_type_name[0]}2#{target_type_name[0]}"
                else
                  @method.send "#{source_type_name[0].chr}2#{target_type_name[0].chr}"
                end
              end
            else
              if (source_type_name != target_type_name ||
                inferred_type(castee).array? != inferred_type(fcall).array?)
                @method.checkcast inferred_type(fcall)
              end
            end
          end
        end

        def visitNodeList(body, expression)
          # last element is an expression only if the body is an expression
          super(body, expression) do |last|
            if last
              visit(last, expression)
            elsif expression
              inferred_type(body).init_value(method)
            end
          end
        end

        def declared_locals
          @declared_locals ||= {}
        end

        def annotate(builder, annotations)
          annotations.each do |annotation|
            type = annotation.type
            type = type.jvm_type if type.respond_to?(:jvm_type)
            builder.annotate(type, annotation.runtime?) do |visitor|
              annotation.values.each do |name, value|
                annotation_value(visitor, name, value)
              end
            end
          end
        end

        def annotation_value(builder, name, value)
          case value
          when Mirah::AST::Annotation
            type = value.type
            type = type.jvm_type if type.respond_to?(:jvm_type)
            builder.annotation(name, type) do |child|
              value.values.each do |name, value|
                annotation_value(child, name, value)
              end
            end
          when ::Array
            builder.array(name) do |array|
              value.each do |item|
                annotation_value(array, nil, item)
              end
            end
          else
            builder.value(name, value)
          end
        end

        def declared?(scope, name)
          declared_locals.include?(scoped_local_name(name, scope))
        end

        def declare_local(scope, name, type)
          # TODO confirm types are compatible
          name = scoped_local_name(name, scope)
          unless declared_locals[name]
            declared_locals[name] = type
            index = @method.local(name, type)
          end
        end

        def declare_locals(scope)
          scope.locals.each do |name|
            unless scope.captured?(name) || declared?(scope, name)
              type = scope.local_type(name)
              declare_local(scope, name, type)
              type.init_value(@method)
              type.store(@method, @method.local(scoped_local_name(name, scope), type))
            end
          end
        end

        def get_binding(type)
          @bindings[type]
        end

        def declared_captures(binding=nil)
          @captured_locals[binding || @binding]
        end

        def visitLocalDeclaration(local, expression)
          scope = get_scope(local)
          if scope.captured?(local.name.identifier)
            captured_local_declare(scope, local.name.identifier, inferred_type(local))
          end
        end

        def captured_local_declare(scope, name, type)
          unless declared_captures[name]
            declared_captures[name] = type
            # default should be fine, but I don't think bitescript supports it.
            @binding.protected_field(name, type)
          end
        end

        def visitLocalAccess(local, expression)
          if expression
            set_position(local.position)
            scope = get_scope(local)
            if scope.captured?(local.name.identifier)
              captured_local(scope, local.name.identifier, inferred_type(local))
            else
              local(scope, local.name.identifier, inferred_type(local))
            end
          end
        end

        def local(scope, name, type)
          type.load(@method, @method.local(scoped_local_name(name, scope), type))
        end

        def captured_local(scope, name, type)
          captured_local_declare(scope, name, type)
          binding_reference
          @method.getfield(scope.binding_type, name, type)
        end

        def visitLocalAssignment(local, expression)
          scope = get_scope(local)
          if scope.captured?(local.name.identifier)
            captured_local_assign(local, expression)
          else
            local_assign(local, expression)
          end
        end

        def local_assign(local, expression)
          name = local.name.identifier
          type = inferred_type(local)
          declare_local(scope, name, type)

          visit(value, true)

          # if expression, dup the value we're assigning
          @method.dup if expression
          set_position(local.position)
          type.store(@method, @method.local(scoped_local_name(name, scope), type))
        end

        def captured_local_assign(node, expression)
          scope, name, type = containing_scope(node), node.name.identifier, inferred_type(node)
          captured_local_declare(scope, name, type)
          binding_reference
          visit(node.value, true)
          @method.dup_x2 if expression
          set_position(node.position)
          @method.putfield(scope.binding_type, name, type)
        end

        def visitFieldAccess(field, expression)
          return nil unless expression
          name = field.name.identifier

          real_type = declared_fields[name] || inferred_type(field)
          declare_field(name, real_type, field.annotations, field.isStatic)

          set_position(field.position)
          # load self object unless static
          method.aload 0 unless static || field.isStatic

          if static || field.isStatic
            @method.getstatic(@class, name, inferred_type(field))
          else
            @method.getfield(@class, name, inferred_type(field))
          end
        end

        def declared_fields
          @declared_fields ||= {}
          @declared_fields[@class] ||= {}
        end

        def declare_field(name, type, annotations, static_field)
          # TODO confirm types are compatible
          unless declared_fields[name]
            declared_fields[name] = type
            field = if static || static_field
              @class.private_static_field name, type
            else
              @class.private_field name, type
            end
            annotate(field, annotations)
          end
        end

        def visitFieldDeclaration(decl, expression)
          declare_field(decl.name.identifier, inferred_type(decl), decl.annotations, decl.isStatic)
        end

        def visitFieldAssign(field, expression)
          name = field.name.identifier

          real_type = declared_fields[name] || inferred_type(field)

          declare_field(name, real_type, field.annotations, field.isStatic)

          method.aload 0 unless static || field.isStatic
          visit(field.value, true)
          if expression
            instruction = 'dup'
            instruction << '2' if type.wide?
            instruction << '_x1' unless static || static_field
            method.send instruction
          end
          set_position(field.position)
          if static || field.isStatic
            @method.putstatic(@class, name, real_type)
          else
            @method.putfield(@class, name, real_type)
          end
        end

        def visitSimpleString(string, expression)
          set_position(string.position)
          @method.ldc(string.value) if expression
        end

        def visitStringConcat(strcat, expression)
          set_position(strcat.position)
          if expression
            # could probably be more efficient with non-default constructor
            builder_class = Mirah::AST.type(nil, 'java.lang.StringBuilder')
            @method.new builder_class
            @method.dup
            @method.invokespecial builder_class, "<init>", [@method.void]

            strcat.strings.each do |node|
              visit(node, true)
              method = find_method(builder_class, "append", [inferred_type(node)], false)
              if method
                @method.invokevirtual builder_class, "append", [method.return_type, *method.argument_types]
              else
                log "Could not find a match for #{java::lang::StringBuilder}.append(#{inferred_type(node)})"
                fail "Could not compile"
              end

            # convert to string
            set_position(strcat.position)
            @method.invokevirtual java::lang::StringBuilder.java_class, "toString", [@method.string]
          else
            nodes.each do |node|
              visit(node, false)
            end
          end
        end

        def visitStringEval(node, expression)
          if expression
            visit(node.value, true)
            set_position(node.position)
            inferred_type(body).box(@method) if inferred_type(body).primitive?
            null = method.label
            done = method.label
            method.dup
            method.ifnull(null)
            @method.invokevirtual @method.object, "toString", [@method.string]
            @method.goto(done)
            null.set!
            method.pop
            method.ldc("null")
            done.set!
          else
            visit(node.value, false)
          end
        end

        def visitBoolean(node, expression)
          if expression
            set_position(node.position)
            node.value ? @method.iconst_1 : @method.iconst_0
          end
        end

        def visitRegex(node, expression)
          # TODO: translate flags to Java-appropriate values
          @method.ldc(node.value)
          setPosition(node.position)
          @method.invokestatic java::util::regex::Pattern, "compile", [java::util::regex::Pattern, @method.string]
        end

        def visitArray(node, expression)
          set_position(node.position)
          if expression
            # create basic arraylist
            @method.new java::util::ArrayList
            @method.dup
            @method.ldc_int node.children ? node.children.size : 0
            @method.invokespecial java::util::ArrayList, "<init>", [@method.void, @method.int]

            # elements, as expressions
            # TODO: ensure they're all reference types!
            node.values.each do |n|
              @method.dup
              visit(n, true)
              # TODO this feels like it should be in the node.compile itself
              if inferred_type(n).primitive?
                inferred_type(n).box(@method)
              end
              @method.invokeinterface java::util::List, "add", [@method.boolean, @method.object]
              @method.pop
            end

            # make it unmodifiable
            @method.invokestatic java::util::Collections, "unmodifiableList", [java::util::List, java::util::List]
          else
            # elements, as non-expressions
            # TODO: ensure they're all reference types!
            node.children.each do |n|
              visit(n, true)
              # TODO this feels like it should be in the node.compile itself
              if inferred_type(n).primitive?
                inferred_type(n).box(@method)
              end
            end
          end
        end

        def visitNull(node, expression)
          if expression
            set_position(node.position)
            @method.aconst_null
          end
        end

        def visitBindingReference(node, expression)
          binding_reference
        end

        def binding_reference
          @method.aload(@method.local('$binding'))
        end

        def real_self
          method.aload(0)
        end

        def line(num)
          @method.line(num - 1) if @method
        end

        def print(print_node)
          @method.getstatic System, "out", PrintStream
          print_node.parameters.each {|param| visit(param, true)}
          params = print_node.parameters.map {|param| inferred_type(param).jvm_type}
          method_name = print_node.println ? "println" : "print"
          method = find_method(PrintStream.java_class, method_name, params, false)
          if (method)
            @method.invokevirtual(
            PrintStream,
            method_name,
            [method.return_type, *method.parameter_types])
          else
            log "Could not find a match for #{PrintStream}.#{method_name}(#{params})"
            fail "Could not compile"
          end
        end

        def visitReturn(return_node, expression)
          visit(return_node.value, true) if return_node.value
          handle_ensures(find_ensures(Mirah::AST::MethodDefinition))
          set_position return_node.position
          inferred_type(return_node).return(@method)
        end

        def visitRaise(node, expression)
          visit(node.args, true)
          set_position(node.position)
          @method.athrow
        end

        def visitRescue(rescue_node, expression)
          start = @method.label.set!
          body_end = @method.label
          done = @method.label
          visit(rescue_node.body, expression && rescue_node.else_clause.size == 0)
          body_end.set!
          visit(rescue_node.else_clause, expression) if rescue_node.else_clause.size > 0
          return if start.label.offset == body_end.label.offset
          @method.goto(done)
          rescue_node.clauses.each do |clause|
            target = @method.label.set!
            if clause.name.identifier
              @method.astore(declare_local(introduced_scope(clause), clause.name.identifier, inferred_type(clause.types)))
            else
              @method.pop
            end
            declare_locals(introduced_scope(clause))
            visit(clause.body, expression)
            @method.goto(done)
            clause.types.each do |type|
              @method.trycatch(start, body_end, target, type)
            end
          end
          done.set!
        end

        def handle_ensures(nodes)
          nodes.each do |ensure_node|
            visit(ensure_node.clause, false)
          end
        end

        def visitEnsure(node, expression)
          node.state = @method.label  # Save the ensure target for JumpNodes
          start = @method.label.set!
          body_end = @method.label
          done = @method.label
          push_jump_scope(node) do
            visit(node.body, expression)  # First compile the body
          end
          body_end.set!
          handle_ensures([node])  # run the ensure clause
          @method.goto(done)  # and continue on after the exception handler
          target = @method.label.set!  # Finally, create the exception handler
          @method.trycatch(start, body_end, target, nil)
          handle_ensures([node])
          @method.athrow
          done.set!
        end

        def empty_array(type, size)
          visit(size, true)
          type.newarray(@method)
        end

        class ClosureCompiler < JVMBytecode
          def initialize(file, type, parent)
            @file = file
            @type = type
            @jump_scope = []
            @parent = parent
            @scopes = parent.scopes
          end

          def prepare_binding(node)
            scope = introduced_scope(node)
            if scope.has_binding?
              type = scope.binding_type
              @binding = @parent.get_binding(type)
              @method.aload 0
              @method.getfield(@class, 'binding', @binding)
              type.store(@method, @method.local('$binding', type))
            end
            begin
              yield
            ensure
              if scope.has_binding?
                @binding = nil
              end
            end
          end

          def declared_captures
            @parent.declared_captures(@binding)
          end
        end
      end
    end
  end
end