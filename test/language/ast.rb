#!/usr/bin/ruby

if __FILE__ == $0
    $:.unshift '../../lib'
    $:.unshift '..'
    $puppetbase = "../.."
end

require 'puppet'
require 'puppet/parser/interpreter'
require 'puppet/parser/parser'
require 'puppet/client'
require 'test/unit'
require 'puppettest'

class TestAST < Test::Unit::TestCase
	include ParserTesting

    # Test that classes behave like singletons
    def test_classsingleton
        parent = child1 = child2 = nil
        children = []

        # create the parent class
        children << classobj("parent")

        # Create child class one
        children << classobj("child1", :parentclass => nameobj("parent"))

        # Create child class two
        children << classobj("child2", :parentclass => nameobj("parent"))
        classes = %w{parent child1 child2}

        # Now call the two classes
        assert_nothing_raised("Could not add AST nodes for calling") {
            children << AST::ObjectDef.new(
                :type => nameobj("child1"),
                :name => nameobj("yayness"),
                :params => astarray()
            )
            children << AST::ObjectDef.new(
                :type => nameobj("child2"),
                :name => nameobj("booness"),
                :params => astarray()
            )
        }

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = nil
        objects = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = scope.evaluate(:ast => top)
        }

        assert_instance_of(Puppet::TransBucket, objects)

        assert_equal(1, scope.find_all { |child|
            if child.is_a? Puppet::Parser::Scope
                child.lookupobject(:name => "/parent", :type => "file")
            else
                nil
            end
        }.length, "Found incorrect number of '/parent' objects")

        assert_equal(classes.sort, scope.classlist.sort)
    end

    # Test that 'tagobject' collects all of an object's parameters and stores
    # them in one TransObject, rather than many.  This is probably a bad idea.
    def test_tagobject
        top = nil
        children = [
            fileobj("/etc", "owner" => "root"),
            fileobj("/etc", "group" => "root")
        ]
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = Puppet::Parser::Scope.new()
        assert_nothing_raised("Could not evaluate") {
            top.evaluate(:scope => scope)
        }

        obj = nil
        assert_nothing_raised("Could not retrieve file object") {
            obj = scope.lookupobject(:name => "/etc", :type => "file")
        }

        assert(obj, "could not retrieve file object")

        %w{owner group}.each { |param|
            assert(obj.include?(param), "Object did not include %s" % param)
        }

    end

    # Verify that objects can only have parents of the same type.
    def test_validparent
        parent = child1 = nil
        children = []

        # create the parent class
        children << compobj("parent", :args => AST::ASTArray.new(:children => []))

        # Create child class one
        children << classobj("child1", :parentclass => nameobj("parent"))

        # Now call the two classes
        assert_nothing_raised("Could not add AST nodes for calling") {
            children << AST::ObjectDef.new(
                :type => nameobj("child1"),
                :name => nameobj("yayness"),
                :params => astarray()
            )
        }

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = nil
        assert_raise(Puppet::ParseError, "Invalid parent type was allowed") {
            scope = Puppet::Parser::Scope.new()
            objects = scope.evaluate(:ast => top)
        }
    end

    # Verify that nodes don't evaluate code in other node scopes but that their
    # facts work outside their scopes.
    def test_nodescopes
        parent = child1 = nil
        topchildren = []

        # create the parent class
        topchildren << classobj("everyone")

        topchildren << classobj("parent")


        classes = %w{everyone parent}

        # And a variable, so we verify the facts get set at the top
        assert_nothing_raised {
            children = []
            children << varobj("yaytest", "$hostname")
        }

        nodes = []

        3.times do |i|
            children = []

            # Create a child class
            topchildren << classobj("perchild#{i}", :parentclass => nameobj("parent"))
            classes << "perchild%s"

            # Create a child class
            children << classobj("child", :parentclass => nameobj("parent"))

            classes << "child"

            ["child", "everyone", "perchild#{i}"].each do |name|
                # Now call our child class
                assert_nothing_raised {
                    children << AST::ObjectDef.new(
                        :type => nameobj(name),
                        :params => astarray()
                    )
                }
            end

            # and another variable
            assert_nothing_raised {
                children << varobj("rahtest", "$hostname")
            }

            # create the node
            nodename = "node#{i}"
            nodes << nodename
            assert_nothing_raised("Could not create parent object") {
                topchildren << AST::NodeDef.new(
                    :names => nameobj(nodename),
                    :code => AST::ASTArray.new(
                        :children => children
                    )
                )
            }
        end

        # Create the wrapper object
        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => topchildren
            )
        }

        nodes.each_with_index do |node, i|
            # Evaluate the parse tree
            scope = Puppet::Parser::Scope.new()
            args = {:names => [node], :facts => {"hostname" => node}, :ast => top}

            # verify that we can evaluate it okay
            trans = nil
            assert_nothing_raised("Could not retrieve node definition") {
                trans = scope.evaluate(args)
            }

            assert_equal(node, scope.lookupvar("hostname"))

            assert(trans, "Could not retrieve trans objects")

            # and that we can convert them to type objects
            objects = nil
            assert_nothing_raised("Could not retrieve node definition") {
                objects = trans.to_type
            }

            assert(objects, "Could not retrieve trans objects")

            count = 0
            # Make sure the node name gets into the path correctly.
            Puppet.type(:file).each { |obj|
                count += 1
                assert(obj.path !~ /#{node}\[#{node}\]/,
                    "Node name appears twice")
            }

            assert(count > 0, "Did not create any files")

            classes.each do |name|
                if name =~ /%s/
                    name = name % i
                end
                assert(Puppet::Type.type(:file)["/#{name}"], "Could not find '#{name}'")
            end

            Puppet::Type.type(:file).clear
        end
    end

    # Verify that classes are correctly defined in node scopes.
    def disabled_test_nodeclasslookup
        parent = child1 = nil
        children = []

        # create the parent class
        children << classobj("parent")

        # Create child class one
        children << classobj("child1", :parentclass => nameobj("parent"))

        # Now call the two classes
        assert_nothing_raised("Could not add AST nodes for calling") {
            children << AST::ObjectDef.new(
                :type => nameobj("child1"),
                :name => nameobj("yayness"),
                :params => astarray()
            )
        }

        # create the node
        nodename = "mynodename"
        node = nil
        assert_nothing_raised("Could not create parent object") {
            node = AST::NodeDef.new(
                :names => nameobj(nodename),
                :code => AST::ASTArray.new(
                    :children => children
                )
            )
        }

        # Create the wrapper object
        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => [node]
            )
        }

        # Evaluate the parse tree
        scope = nil
        assert_nothing_raised("Could not evaluate node") {
            scope = Puppet::Parser::Scope.new()
            top.evaluate(:scope => scope)
        }

        # Verify that, well, nothing really happened, and especially verify
        # that the top scope is not a node scope
        assert(scope.topscope?, "Scope is not top scope")
        assert(! scope.nodescope?, "Scope is mistakenly node scope")
        assert(! scope.lookupclass("parent"), "Found parent class in top scope")

        # verify we can find our node
        assert(scope.node(nodename), "Could not find node")

        # And verify that we can evaluate it okay
        objects = nil
        assert_nothing_raised("Could not retrieve node definition") {
            objects = scope.evalnode(:name => [nodename], :facts => {})
        }

        assert(objects, "Could not retrieve node definition")

        # Because node scopes are temporary (i.e., they get destroyed after the node's
        # config is returned) we should not be able to find the node scope.
        nodescope = nil
        assert_nothing_raised {
            nodescope = scope.find { |child|
                child.nodescope?
            }
        }

        assert_nil(nodescope, "Found nodescope")

        # And now verify again that the top scope cannot find the node's definition
        # of the parent class
        assert(! scope.lookupclass("parent"), "Found parent class in top scope")

        trans = nil
        # Verify that we can evaluate the node twice
        assert_nothing_raised("Could not retrieve node definition") {
            trans = scope.evalnode(:name => [nodename], :facts => {})
        }

        objects = nil
        assert_nothing_raised("Could not convert to objects") {
            objects = trans.to_type
        }

        Puppet.type(:file).each { |obj|
            assert(obj.path !~ /#{nodename}\[#{nodename}\]/,
                "Node name appears twice")
        }

        assert(Puppet::Type.type(:file)["/child1"], "Could not find child")
        assert(Puppet::Type.type(:file)["/parent"], "Could not find parent")
    end

    # Test that you can look a host up using multiple names, e.g., an FQDN and
    # a short name
    def test_multiplenodenames
        children = []

        # create a short-name node
        shortname = "mynodename"
        children << nodedef(shortname)

        # And a long-name node
        longname = "node.domain.com"
        children << nodedef(longname)

        # Create the wrapper object
        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        # Evaluate the parse tree
        scope = Puppet::Parser::Scope.new()

        # Verify we can find the node via a search list
        objects = nil
        assert_nothing_raised("Could not retrieve short node definition") {
            objects = scope.evaluate(
                :names => ["%s.domain.com" % shortname, shortname], :facts => {},
                :ast => top
            )
        }
        assert(objects, "Could not retrieve short node definition")

        scope = Puppet::Parser::Scope.new()

        # and then look for the long name
        assert_nothing_raised("Could not retrieve long node definition") {
            objects = scope.evaluate(
                :names => [longname.sub(/\..+/, ''), longname], :facts => {},
                :ast => top
            )
        }
        assert(objects, "Could not retrieve long node definition")
    end

    # Test that a node gets the entire configuration except for work meant for
    # another node
    def test_fullconfigwithnodes
        children = []

        children << fileobj("/testing")

        # create a short-name node
        name = "mynodename"
        children << nodedef(name)

        # Create the wrapper object
        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = Puppet::Parser::Scope.new()

        # Verify we can find the node via a search list
        objects = nil
        assert_nothing_raised("Could not retrieve short node definition") {
            objects = scope.evaluate(:names => [name], :facts => {}, :ast => top)
        }
        assert(objects, "Could not retrieve short node definition")
        assert_instance_of(Puppet::TransBucket, objects)

        # And now verify that we got both the top and node objects
        assert_nothing_raised("Could not find top-declared object") {
            assert_equal("/testing", objects[0].name)
        }

        assert_nothing_raised("Could not find node-declared object %s" %
            "/%s" % name
        ) {
            assert_equal("/%s" % name, objects[1][0].name)
        }
    end

    # Test that we can 'include' variables, not just normal strings.
    def test_includevars
        children = []
        classes = []

        # Create our class for testin
        klassname = "include"
        children << classobj(klassname)
        classes << klassname

        # Then add our variable assignment
        children << varobj("klassvar", klassname)

        # And finally add our calling of the variable
        children << AST::ObjectDef.new(
            :type => AST::Variable.new(:value => "klassvar"),
            :params => astarray
        )

        # And then create our top object
        top = AST::ASTArray.new(
            :children => children
        )

        # Evaluate the parse tree
        scope = nil
        objects = nil
        assert_nothing_raised("Could not evaluate node") {
            scope = Puppet::Parser::Scope.new()
            objects = scope.evaluate(:ast => top)
        }

        # Verify we get the right classlist back
        assert_equal(classes.sort, scope.classlist.sort)

        # Verify we can find the node via a search list
        #assert_nothing_raised("Could not retrieve objects") {
        #    objects = scope.to_trans
        #}
        assert(objects, "Could not retrieve objects")

        assert_nothing_raised("Could not find top-declared object") {
            assert_equal("/%s" % klassname, objects[0][0].name)
        }
    end

    # Test that node inheritance works correctly
    def test_nodeinheritance
        children = []

        # create the base node
        name = "basenode"
        children << nodedef(name)

        # and the sub node
        name = "subnode"
        children << AST::NodeDef.new(
            :names => nameobj(name),
            :parentclass => nameobj("basenode"),
            :code => AST::ASTArray.new(
                :children => [
                    varobj("%svar" % name, "%svalue" % name),
                    fileobj("/%s" % name)
                ]
            )
        )
        #subnode = nodedef(name)
        #subnode.parentclass = "basenode"

        #children << subnode

        # and the top object
        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        # Evaluate the parse tree
        scope = Puppet::Parser::Scope.new()

        # Verify we can find the node via a search list
        objects = nil
        assert_nothing_raised("Could not evaluate node") {
            objects = scope.evaluate(:names => [name], :facts => {}, :ast => top)
        }
        assert(objects, "Could not retrieve node definition")

        assert_nothing_raised {
            inner = objects[0]

            # And now verify that we got the subnode file
            assert_nothing_raised("Could not find basenode file") {
                base = inner[0]
                assert_equal("/basenode", base.name)
            }

            # and the parent node file
            assert_nothing_raised("Could not find subnode file") {
                sub = inner[1]
                assert_equal("/subnode", sub.name)
            }

            inner.each { |obj|
                %w{basenode subnode}.each { |tag|
                    assert(obj.tags.include?(tag),
                        "%s did not include %s tag" % [obj.name, tag]
                    )
                }
            }
        }
    end

    def test_typechecking
        object = nil
        children = []
        type = "deftype"
        assert_nothing_raised("Could not add AST nodes for calling") {
            object = AST::ObjectDef.new(
                :type => nameobj(type),
                :name => nameobj("yayness"),
                :params => astarray()
            )
        }

        assert_nothing_raised("Typecheck failed") {
            object.typecheck(type)
        }

        # Add a scope, which makes it think it's evaluating
        assert_nothing_raised {
            scope = Puppet::Parser::Scope.new()
            object.scope = scope
        }

        # Verify an error is thrown when it can't find the type
        assert_raise(Puppet::ParseError) {
            object.typecheck(type)
        }

        # Create child class one
        children << classobj(type)
        children << object

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = top.evaluate(:scope => scope)
        }
    end

    def disabled_test_paramcheck
        object = nil
        children = []
        type = "deftype"
        params = %w{param1 param2}

        comp = compobj(type, {
            :args => astarray(
                argobj("param1", "yay"),
                argobj("param2", "rah")
            ),
            :code => AST::ASTArray.new(
                :children => [
                    varobj("%svar" % name, "%svalue" % name),
                    fileobj("/%s" % name)
                ]
            )
        })
        assert_nothing_raised("Could not add AST nodes for calling") {
            object = AST::ObjectDef.new(
                :type => nameobj(type),
                :name => nameobj("yayness"),
                :params => astarray(
                    astarray(stringobj("param1"), stringobj("value1")),
                    astarray(stringobj("param2"), stringobj("value2"))
                )
            )
        }

        # Add a scope, which makes it think it's evaluating
        assert_nothing_raised {
            scope = Puppet::Parser::Scope.new()
            object.scope = scope
        }

        # Verify an error is thrown when it can't find the type
        assert_raise(Puppet::ParseError) {
            object.paramcheck(false, comp)
        }

        # Create child class one
        children << classobj(type)
        children << object

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = top.evaluate(:scope => scope)
        }
    end

    def test_setclass
        type = "yay"
        classes = [type]
        children = []
        # Create child class one
        children << varobj("variable", "aclass")
        children << tagobj(type, varref("variable"))
        children << tagobj(type)

        classes << "aclass"

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = top.evaluate(:scope => scope)
        }


        classes.each do |tag|
            assert(scope.classlist.include?(tag), "Did not set class %s" % tag)
        end

    end

    # Test that we strip the domain off of host names before they are set as classes
    def test_nodenamestrip
        children = []

        longname = "node.domain.com"
        children << nodedef(longname)

        # Create the wrapper object
        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        scope = Puppet::Parser::Scope.new()

        assert_nothing_raised("Could not evaluate node") {
            objects = scope.evaluate(:names => [longname], :facts => {}, :ast => top)
        }

        assert(!scope.classlist.include?("node.domain.com"),
            "Node's long name got set")
        assert(scope.classlist.include?("node"), "Node's name did not get set")
    end

    # Make sure that deep class parentage works
    def test_classparentage
        children = []
        files = []
        base = classobj("base")
        files << "/base"

        children << base

        parent = "base"
        5.times { |i|
            name = "child%s" % i
            files << "/%s" % name
            children << classobj(name, :parentclass => nameobj(parent))

            parent = name
        }

        children << functionobj("include", parent)

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        objects = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = scope.evaluate(:ast => top)
        }

        objects = objects.flatten

        files.each do |file|
            assert(objects.find { |o| o.name == file },
                "Could not find file %s" % file)
        end
    end

    # Make sure we catch names that are specified like parameters.
    def test_name_or_param
        obj = nil
        assert_nothing_raised {
            obj = AST::ObjectDef.new(
                :type => nameobj("file"),
                :params => astarray(AST::ObjectParam.new(
                    :param => stringobj("name"),
                    :value => stringobj("yayness")
                ))
            )
        }

        scope = Puppet::Parser::Scope.new

        trans = nil
        assert_nothing_raised {
            trans = scope.evaluate(:ast => obj, :facts => {})
        }

        transobj = trans.shift
        assert(transobj.name, "Name did not convert from param to name")
    end

    if defined? ActiveRecord
    # Verify that our collection stuff works.
    def test_collection
        collectable = []
        non = []
        # First put some objects into the database.
        bucket = mk_transtree do |object, depth, width|
            # and mark some of them collectable
            if width % 2 == 1
                object.collectable = true
                collectable << object
            else
                non << object
            end
        end

        # Now collect our facts
        facts = {}
        Facter.each do |fact, value| facts[fact] = value end

        assert_nothing_raised {
            Puppet::Rails.init
        }

        # Now try storing our crap
        assert_nothing_raised {
            host = Puppet::Rails::Host.store(
                :objects => bucket,
                :facts => facts,
                :host => facts["hostname"]
            )
        }

        # Now create an ast tree that collects that.  They should all be files.
        coll = nil
        assert_nothing_raised {
            coll = AST::Collection.new(
                :type => nameobj("file")
            )
        }

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => [coll]
            )
        }

        objects = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = scope.evaluate(:ast => top).flatten
        }

        assert(objects.length > 0, "Did not receive any collected objects")
    end
    else
        $stderr.puts "No ActiveRecord -- skipping collection tests"
    end

    # To fix #140.  Currently non-functional.
    def disabled_test_classreuse
        children = []

        # Create the parent class, with a definition in it.
        children << classobj("parent", :code => AST::ASTArray.new(
            :file => __FILE__,
            :line => __LINE__,
            :children => [
                compobj("foo", :args => AST::ASTArray.new(
                        :children => [nameobj("arg")]
                    ),
                    :code => AST::ASTArray.new(
                        :file => __FILE__,
                        :line => __LINE__,
                        :children => [fileobj("/$arg")]
                    )
                ),
                objectdef("foo", "ptest", {"arg" => "parentfoo"})
            ]
        ))

        # Create child class, also trying to use that definition
        children << classobj("child1", :parentclass => nameobj("parent"),
            :code => AST::ASTArray.new(
                :file => __FILE__,
                :line => __LINE__,
                :children => [
                    objectdef("foo", "ctest", {"arg" => "childfoo"})
                ]
            )
        )

        # Call the parent first
        children << functionobj("include", "parent")

        # Then call the child, and make sure it can look up the definition
        children << functionobj("include", "child1")

        top = nil
        assert_nothing_raised("Could not create top object") {
            top = AST::ASTArray.new(
                :children => children
            )
        }

        objects = nil
        assert_nothing_raised("Could not evaluate") {
            scope = Puppet::Parser::Scope.new()
            objects = scope.evaluate(:ast => top)
        }
    end
end

# $Id$
