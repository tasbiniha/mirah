module Mirah
  module JVM
    module Types
      class Type
        java_import 'org.mirah.typer.ErrorType'
        java_import 'org.mirah.typer.SpecialType'
        java_import 'org.mirah.typer.ResolvedType'

        class SpecialType
          def full_name
            name
          end
        end

        include Java::DubyLangCompiler::Class
        include Mirah::JVM::MethodLookup
        include ResolvedType

        attr_reader :name, :type_system
        attr_writer :inner_class

        def log(message)
          puts "* [JVM::Types] #{message}" if Mirah::JVM::Compiler::JVMBytecode.verbose
        end

        def initialize(type_system, mirror_or_name)
          @type_system = type_system
          if mirror_or_name.kind_of?(BiteScript::ASM::ClassMirror)
            @type = mirror_or_name
            @name = mirror_or_name.type.class_name
          else
            @name = mirror_or_name.to_s
          end
          raise ArgumentError, "Bad type #{mirror_or_name}" if name =~ /Java::/
        end

        def full_name
          desc = BiteScript::Signature.class_id(self)
          BiteScript::ASM::Type.get_type(desc).class_name
        end

        def jvm_type
          @type
        end

        def void?
          false
        end

        def meta?
          false
        end
        def isMeta
          self.meta?
        end

        def array?
          false
        end
        def isArray
          self.array?
        end

        def primitive?
          false
        end

        def interface?
          # FIXME: Don't do rescue nil. Figure out a cleaner way to handle
          # mirrors for all incoming types without blowing up on e.g. 'boolean' or 'int'
          (@type || BiteScript::ASM::ClassMirror.for_name(@name)).interface? rescue nil
        end

        def dynamic?
          false
        end

        def inner_class?
          @inner_class
        end

        def is_parent(other)
          assignable_from?(other)
        end

        def compatible?(other)
          assignable_from?(other)
        end

        def error?
          false
        end
        def isError
          false
        end

        def assignable_from?(other)
          return false if other.nil?
          return true if !primitive? && other.name == 'null'
          return true if other == self
          return true if other.error? || other.name == ':unreachable'

          # TODO should we allow more here?
          return interface? if other.name == ':block'

          return true if jvm_type && (jvm_type == other.jvm_type)

          assignable_from?(other.superclass) ||
              other.interfaces.any? {|i| assignable_from?(i)}
        end
        def assignableFrom(other)
          assignable_from?(other)
        end

        def widen(other)
          return other if other.isError
          common_parent = (ancestors_and_interfaces & other.ancestors_and_interfaces)[0]
          common_parent || ErrorType.new([["Incompatible types #{self} and #{other}."]])
        end

        def iterable?
          ['java.lang.Iterable',
           'java.util.Iterator',
           'java.util.Enumeration'].any? {|n| @type_system.type(nil, n).assignable_from(self)}
        end

        def component_type
          @type_system.type(nil, 'java.lang.Object') if iterable?
        end

        def meta
          @meta ||= MetaType.new(self)
        end

        def unmeta
          self
        end

        def basic_type
          self
        end

        def array_type
          @array_type ||= Mirah::JVM::Types::ArrayType.new(self)
        end

        def prefix
          'a'
        end

        # is this a 64 bit type?
        def wide?
          false
        end

        def inspect(indent=0)
          "#{' ' * indent}#<#{self.class.name.split(/::/)[-1]} #{name}>"
        end

        def to_s
          inspect
        end

        def newarray(method)
          method.anewarray(self)
        end

        def pop(method)
          if wide?
            method.pop2
          else
            method.pop
          end
        end

        def superclass
          raise "Incomplete type #{self}" unless jvm_type
          @type_system.type(nil, jvm_type.superclass) if jvm_type.superclass
        end

        def interfaces(include_parent=true)
          raise "Incomplete type #{self} (#{self.class})" unless jvm_type
          @interfaces ||= begin
            interfaces = jvm_type.interfaces.map {|i| @type_system.type(nil, i)}.to_set
            if superclass && include_parent
              interfaces |= superclass.interfaces
            end
            interfaces.to_a
          end
          @interfaces
        end

        def ancestors_and_interfaces
          if self.primitive?
            []
          else
            ancestors = []
            get_ancestors = lambda {|c| [c.superclass] + c.interfaces(false)}
            new_ancestors = get_ancestors.call(self)
            until new_ancestors.empty?
              klass = new_ancestors.shift
              next if klass.nil? || klass.name == 'java.lang.Object'
              ancestors << klass
              new_ancestors.concat(get_ancestors.call(klass))
            end
            ancestors << @type_system.type(nil, 'java.lang.Object')
            ancestors
          end
        end

        def astore(builder)
          if primitive?
            builder.send "#{name[0,1]}astore"
          else
            builder.aastore
          end
        end

        def aload(builder)
          if primitive?
            builder.send "#{name[0,1]}aload"
          else
            builder.aaload
          end
        end
      end
    end
  end
end