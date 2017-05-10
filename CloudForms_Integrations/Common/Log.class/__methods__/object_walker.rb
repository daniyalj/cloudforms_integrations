#
# object_walker
#
# Can be called from anywhere in the CloudForms / ManageIQ automation namespace, and will walk the automation object structure starting from $evm.root
# and dump (to automation.log) its attributes, any objects found, their attributes, virtual columns, and associations, and so on.
#
# Author:   Peter McGowan (pemcg@redhat.com)
#           Copyright 2014 Peter McGowan, Red Hat
#
# Revision History
#
# Original      1.0     18-Sep-2014
#               1.1     22-Sep-2014     Added blacklisting/whitelisting to the walk_association functionality
#               1.2     24-Sep-2014     Changed exception handling logic slightly
#               1.3     25-Sep-2014     Debugged exception handling, changed some output strings
#               1.4     15-Feb-2015     Added dump_methods, renamed to object_walker
#               1.4-1   19-Feb-2015     Changed singular/plural detection code in dump_association to use active_support/core_ext/string
#               1.4-2   27-Feb-2015     Dump some $evm attributes first, and print the URI for an object type of DRb::DRbObject
#               1.4-3   02-Mar-2015     Detect duplicate entries in the associations list for each object
#               1.4-4   08-Mar-2015     Walk $evm.parent after $evm.root
#               1.4-5   29-Mar-2015     Only dump the associations, methods and virtual columns of an MiqAeMethodService::* class
#               1.4-6   14-Apr-2015     Dump $evm.current.attributes if there are any (arguments passed from a $evm.instantiate call)
#                                       e.g. $evm.instantiate("Discovery/Methods/ObjectWalker?provider=#{provider}&lunch=sandwich")
#               1.4-7   14-Apr-2015     Don't try to dump $evm.parent if it's a NilClass (e.g. if vmdb_object_type = automation_task)
#               1.5     15-Apr-2015     Correctly format attributes that are actually hash keys (object['attribute'] rather than
#                                       object.attribute). This includes most of the attributes of $evm.root which had previously
#                                       been displayed incorrectly
#               1.5-1   16-Apr-2015     Fixed a bug where sometimes the return from calling object.attributes isn't iterable
#               1.5-2   16-Apr-2015     Dump $evm.object rather than $evm.current - they are the same but more code examples use
#                                       $evm.object so it's less ambiguous and possibly more useful to dump this
#               1.5-3   12-Jul-2015     Refactored dump_attributes slightly to allow for the fact that options hash keys can be strings
#                                       or symbols (a mix of the two causes sort to error)
#
require 'active_support/core_ext/string'
@method = 'object_walker'
VERSION = "1.5-3"
#
@recursion_level = 0
@object_recorder = {}
@debug = false
#
# Change MAX_RECURSION_LEVEL to adjust the depth of recursion that object_walker traverses through the objects
#
MAX_RECURSION_LEVEL = 7
#
# @print_nil_values can be used to toggle whether or not to include keys that have a nil value in the
# output dump. There are often many, and including them will usually increase verbosity, but it is
# sometimes useful to know that a key/attribute exists, even if it currently has no assigned value.
#
@print_nil_values = true
#
# @dump_methods defines whether or not we dump the methods of each object that we encounter. We only dump the methods
# of the object and its superclasses up to but not including the methods of MiqAeMethodService::MiqAeServiceModelBase.
# For actual usage of the methods, expected arguments, etc., consult the code itself (or documentation).
#
@dump_methods = true
#
# We need to record the instance methods of the MiqAeMethodService::MiqAeServiceModelBase class so that we can
# subtract this list from the methods we discover for each object
#
@service_mode_base_instance_methods = []
#
# @walk_association_policy should have the value of either :whitelist or :blacklist. This will determine whether we either 
# walk all associations _except_ those in the @walk_association_blacklist hash, or _only_ the associations in the
# @walk_association_whitelist hash
#
@walk_association_policy = :whitelist
#
# if @walk_association_policy = :whitelist, then object_walker will only traverse associations of objects that are explicitly
# mentioned in the @walk_association_whitelist hash. This enables us to carefully control what is dumped. If object_walker finds
# an association that isn't in the hash, it will print a line similar to:
#
# $evm.root['vm'].datacenter (type: Association, objects found)
#   (datacenter isn't in the @walk_associations hash for MiqAeServiceVmRedhat...)
#
# If you wish to explore and dump this association, edit the hash to add the association name to the list associated with the object type. The symbol
# :ALL can be used to walk all associations of an object type
#
@walk_association_whitelist = { "MiqAeServiceServiceTemplateProvisionTask" => ["source", "destination", "miq_request", "miq_request_tasks", "service_resource"],
                                "MiqAeServiceServiceTemplateProvisionRequest" => ["miq_request", "miq_request_tasks", "requester", "resource", "source"],
                                "MiqAeServiceServiceTemplate" => ["service_resources"],
                                "MiqAeServiceServiceResource" => ["resource", "service_template"],
                                "MiqAeServiceMiqProvisionRequest" => ["miq_request", "miq_request_tasks", \
                                                                      "miq_provisions", "requester", "resource", "source", "vm_template"],
                                "MiqAeServiceMiqProvisionRequestTemplate" => ["miq_request", "miq_request_tasks"],
                                "MiqAeServiceMiqProvisionVmware" => ["source", "destination", "miq_provision_request", "miq_request", "miq_request_task", "vm", \
                                                                     "vm_template"],
                                "MiqAeServiceMiqProvisionRedhat" => [:ALL],
                                "MiqAeServiceMiqProvisionRedhatViaPxe" => [:ALL],
                                "MiqAeServiceVmVmware" => ["ems_cluster", "ems_folder", "resource_pool", "ext_management_system", "storage", "service", "hardware", \
                                                           "operating_system"],
                                "MiqAeServiceVmRedhat" => ["ems_cluster", "ems_folder", "resource_pool", "ext_management_system", "storage", "service", "hardware"],
                                "MiqAeServiceHardware" => ["nics", "guest_devices", "ports", "vm" ],
                                "MiqAeServiceUser" => ["current_group"],
                                "MiqAeServiceGuestDevice" => ["hardware", "lan", "network"]}
#
# if @walk_association_policy = :blacklist, then object_walker will traverse all associations of all objects, except those
# that are explicitly mentioned in the @walk_association_blacklist hash. This enables us to run a more exploratory dump, at the cost of a
# much more verbose output. The symbol:ALL can be used to prevent walking any associations of an object type
#
# You have been warned, using a blacklist walk_association_policy produces a lot of output!
#
@walk_association_blacklist = { "MiqAeServiceEmsRedhat" => ["ems_events"],
                                "MiqAeServiceEmsVmware" => ["ems_events"],
                                "MiqAeServiceEmsCluster" => ["all_vms", "vms", "ems_events"],
                                "MiqAeServiceHostRedhat" => ["guest_applications", "ems_events"],
                                "MiqAeServiceHostVmwareEsx" => ["guest_applications", "ems_events"]}


#-------------------------------------------------------------------------------------------------------------
# Method:       type
# Purpose:      Returns a string containing the type of the object passed as an argument
# Arguments:    object: object to be type tested
# Returns:      string
#-------------------------------------------------------------------------------------------------------------

def type(object)
  if object.is_a?(DRb::DRbObject)
    string = "(type: #{object.class}, URI: #{object.__drburi()})"
  else
    string = "(type: #{object.class})"
  end
  return string
end

# End of type
#-------------------------------------------------------------------------------------------------------------

#-------------------------------------------------------------------------------------------------------------
# Method:       ping_attr
# Purpose:      Some attributes returned by object.attributes are actually hash keys rather than
#               attributes. We need to know which is which so that we can format our pretty output
#               correctly, so here we try to access the attribute as a method, and if that fails
#               we try to access it as a hash key
# Arguments:    this_object: object to be tested
#               attribute: the attribute to be tested
# Returns:      hash {:format_string => ".attribute" | "['attribute']", :value => value} 
#-------------------------------------------------------------------------------------------------------------

def ping_attr(this_object, attribute)
  value = "<unreadable_value>"
  format_string = ".<unknown_attribute>"
  begin
    #
    # See if it's an attribute that we access using '.attribute'
    #
    value = this_object.send(attribute)
    format_string = ".#{attribute}"
  rescue NoMethodError
    #
    # Seems not, let's try to access as if it's a hash value
    #
    value = this_object[attribute]
    format_string = "['#{attribute}']"
  end
  return {:format_string => format_string, :value => value}
end

# End of ping_attr
#-------------------------------------------------------------------------------------------------------------

#-------------------------------------------------------------------------------------------------------------
# Method:       str_or_sym
# Purpose:      format a string containing the argument correctly depending on whether the value
#               is a symbol or string
# Arguments:    value: the thing to be string-formatted
# Returns:      string containing either ":value" or "'value'"
#-------------------------------------------------------------------------------------------------------------

def str_or_sym(value)
  value_as_string = ""
  if value.is_a?(Symbol)
    value_as_string = ":#{value}"
  else
    value_as_string = "\'#{value}\'"
  end
  return value_as_string
end

# End of str_or_sym
#-------------------------------------------------------------------------------------------------------------


#-------------------------------------------------------------------------------------------------------------
# Method:       dump_attributes
# Purpose:      Dump the attributes of an object
# Arguments:    object_string : 
#               this_object
#               indent_string
# Returns:      None
#-------------------------------------------------------------------------------------------------------------
def dump_attributes(object_string, this_object, indent_string)
  begin
    #
    # Print the attributes of this object
    #
    if this_object.respond_to?(:attributes)
      $evm.log("info", "#{indent_string}#{@method}:   Debug: this_object.inspected = #{this_object.inspect}") if @debug
      if this_object.attributes.respond_to?(:keys)
        this_object.attributes.keys.sort.each do |attribute_name|
          attribute_value = this_object.attributes[attribute_name]
          if attribute_name != "options"
            if attribute_value.is_a?(DRb::DRbObject)
              if attribute_value.method_missing(:class).to_s =~ /^MiqAeMethodService.*/
                $evm.log("info", "#{indent_string}#{@method}:   #{object_string}[\'#{attribute_name}\'] => #{attribute_value}   #{type(attribute_value)}")
                dump_object("#{object_string}[\'#{attribute_name}\']", attribute_value, indent_string)
              else
                $evm.log("info", "#{indent_string}#{@method}:   Debug: not dumping, attribute_value.method_missing(:class) = #{attribute_value.method_missing(:class)}") if @debug
              end
            else
              begin
                attr_info = ping_attr(this_object, attribute_name)
                if attr_info[:value].nil?
                  $evm.log("info", "#{indent_string}#{@method}:   #{object_string}#{attr_info[:format_string]} = nil") if @print_nil_values
                else
                  $evm.log("info", "#{indent_string}#{@method}:   #{object_string}#{attr_info[:format_string]} = #{attr_info[:value]}   #{type(attr_info[:value])}")
                end
              rescue ArgumentError
                if attribute_value.nil?
                  $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{attribute_name} = nil") if @print_nil_values
                else
                  $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{attribute_name} = #{attribute_value}   #{type(attribute_value)}")
                end
              end
            end
          else
            #
            # Option key names can be mixed symbols and strings which confuses .sort
            # Create an option_map hash that maps option_name.to_s => option_name
            #
            option_map = {}
            options = attribute_value.keys
            options.each do |option_name|
              option_map[option_name.to_s] = option_name
            end
            option_map.keys.sort.each do |option|
              if attribute_value[option_map[option]].nil?
                $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.options[#{str_or_sym(option_map[option])}] = nil") if @print_nil_values
              else
                $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.options[#{str_or_sym(option_map[option])}] = #{attribute_value[option_map[option]]}   #{type(attribute_value[option_map[option]])}")
              end
            end
          end
        end
      else
        $evm.log("info", "#{indent_string}#{@method}:   *** #{object_string} attributes are not iterable ***")
      end
    else
      $evm.log("info", "#{indent_string}#{@method}:   #{object_string} has no attributes")
    end 
  rescue => err
    $evm.log("error", "#{@method} (dump_attributes) - [#{err}]\n#{err.backtrace.join("\n")}")
  end
end

# End of dump_attributes
#-------------------------------------------------------------------------------------------------------------


#-------------------------------------------------------------------------------------------------------------
# Method:       dump_virtual_columns
# Purpose:      Dumps the virtual_columns_names of the object passed to it
# Arguments:    object_string     : friendly text string name for the object
#               this_object       : the Ruby object whose virtual_column_names are to be dumped
#               this_object_class : the class of the object whose associations are to be dumped
#               indent_string     : the string to use to indent the output (represents recursion depth)
# Returns:      None
#-------------------------------------------------------------------------------------------------------------

def dump_virtual_columns(object_string, this_object, this_object_class, indent_string)
  begin
    #
    # Only dump the virtual columns of an MiqAeMethodService::* class
    #
    if this_object.method_missing(:class).to_s =~ /^MiqAeMethodService.*/
      #
      # Print the virtual columns of this object 
      #
      if this_object.respond_to?(:virtual_column_names)
        $evm.log("info", "#{indent_string}#{@method}:   --- virtual columns follow ---")
        this_object.virtual_column_names.sort.each do |virtual_column_name|
          begin
            virtual_column_value = this_object.send(virtual_column_name)
            if virtual_column_value.nil?
              $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{virtual_column_name} = nil") if @print_nil_values
            else
              $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{virtual_column_name} = #{virtual_column_value}   #{type(virtual_column_value)}")
            end
          rescue NoMethodError
            $evm.log("info", "#{indent_string}#{@method}:   *** #{this_object_class} virtual column: \'#{virtual_column_name}\' gives a NoMethodError when accessed (product bug?) ***")
          end
        end
        $evm.log("info", "#{indent_string}#{@method}:   --- end of virtual columns ---")
      else
        $evm.log("info", "#{indent_string}#{@method}:   #{object_string} has no virtual columns")
      end
    end
  rescue => err
    $evm.log("error", "#{@method} (dump_virtual_columns) - [#{err}]\n#{err.backtrace.join("\n")}")
  end
end

# End of dump_virtual_columns
#-------------------------------------------------------------------------------------------------------------

#-------------------------------------------------------------------------------------------------------------
# Method:       is_plural?
# Purpose:      Test whather a string is plural (as opposed to singular)
# Arguments:    astring: text string to be tested
# Returns:      Boolean
#-------------------------------------------------------------------------------------------------------------

def is_plural?(astring)
  astring.singularize != astring
end

# End of is_plural?
#-------------------------------------------------------------------------------------------------------------

#-------------------------------------------------------------------------------------------------------------
# Method:       dump_association
# Purpose:      Dumps the association of the object passed to it
# Arguments:    object_string       : friendly text string name for the object
#               association         : friendly text string name for the association
#               associated_objects  : the list of objects in the association
#               indent_string       : the string to use to indent the output (represents recursion depth)
# Returns:      None
#-------------------------------------------------------------------------------------------------------------

def dump_association(object_string, association, associated_objects, indent_string)
  begin
    #
    # Assemble some fake code to make it look like we're iterating though associations (plural)
    #
    number_of_associated_objects = associated_objects.length
    if is_plural?(association)
      assignment_string = "#{object_string}.#{association}.each do |#{association.singularize}|"
    else
      assignment_string = "#{association} = #{object_string}.#{association}"
    end
    $evm.log("info", "#{indent_string}#{@method}:   #{assignment_string}")
    associated_objects.each do |associated_object|
      associated_object_class = "#{associated_object.method_missing(:class)}".demodulize
      associated_object_id = associated_object.id rescue associated_object.object_id
      $evm.log("info", "#{indent_string}|    #{@method}:   (object type: #{associated_object_class}, object ID: #{associated_object_id})")
      if is_plural?(association)
        dump_object("#{association.singularize}", associated_object, indent_string)
        if number_of_associated_objects > 1
          $evm.log("info", "#{indent_string}#{@method}:   --- next #{association.singularize} ---")
          number_of_associated_objects -= 1
        else
          $evm.log("info", "#{indent_string}#{@method}:   --- end of #{object_string}.#{association}.each do |#{association.singularize}| ---")
        end
      else
        dump_object("#{association}", associated_object, indent_string)
      end
    end
  rescue => err
    $evm.log("error", "#{@method} (dump_association) - [#{err}]\n#{err.backtrace.join("\n")}")
  end
end

# End of dump_association
#-------------------------------------------------------------------------------------------------------------


#-------------------------------------------------------------------------------------------------------------
# Method:       dump_associations
# Purpose:      Dumps the associations (if any) of the object passed to it
# Arguments:    object_string     : friendly text string name for the object
#               this_object       : the Ruby object whose associations are to be dumped
#               this_object_class : the class of the object whose associations are to be dumped
#               indent_string     : the string to use to indent the output (represents recursion depth)
# Returns:      None
#-------------------------------------------------------------------------------------------------------------

def dump_associations(object_string, this_object, this_object_class, indent_string)
  begin
    #
    # Only dump the associations of an MiqAeMethodService::* class
    #
    if this_object.method_missing(:class).to_s =~ /^MiqAeMethodService.*/
      #
      # Print the associations of this object according to the @walk_associations_whitelist & @walk_associations_blacklist hashes
      #
      object_associations = []
      associated_objects = []
      duplicates = []
      if this_object.respond_to?(:associations)
        $evm.log("info", "#{indent_string}#{@method}:   --- associations follow ---")
        object_associations = Array(this_object.associations)
        duplicates = object_associations.select{|item| object_associations.count(item) > 1}
        if duplicates.length > 0
          $evm.log("info", "#{indent_string}#{@method}:   *** De-duplicating the following associations: #{duplicates.inspect} (product bug?) ***")
        end
        object_associations.uniq.sort.each do |association|
          begin
            associated_objects = Array(this_object.send(association))
            if associated_objects.length == 0
              $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{association} (type: Association (empty))")
            else
              $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{association} (type: Association)")
              #
              # See if we need to walk this association according to the @walk_association_policy variable, and the @walk_association_{whitelist,blacklist} hashes
              #
              if @walk_association_policy == :whitelist
                if @walk_association_whitelist.has_key?(this_object_class) &&
                    (@walk_association_whitelist[this_object_class].include?(:ALL) || @walk_association_whitelist[this_object_class].include?(association.to_s))
                  dump_association(object_string, association, associated_objects, indent_string)
                else
                  $evm.log("info", "#{indent_string}#{@method}:   *** not walking: \'#{association}\' isn't in the @walk_association_whitelist hash for #{this_object_class} ***")
                end
              elsif @walk_association_policy == :blacklist
                if @walk_association_blacklist.has_key?(this_object_class) &&
                    (@walk_association_blacklist[this_object_class].include?(:ALL) || @walk_association_blacklist[this_object_class].include?(association.to_s))
                  $evm.log("info", "#{indent_string}#{@method}:   *** not walking: \'#{association}\' is in the @walk_association_blacklist hash for #{this_object_class} ***")
                else
                  dump_association(object_string, association, associated_objects, indent_string)
                end
              else
                $evm.log("info", "#{indent_string}#{@method}:   *** Invalid @walk_association_policy: #{@walk_association_policy} ***")
                exit MIQ_ABORT
              end
            end
          rescue NoMethodError
            $evm.log("info", "#{indent_string}#{@method}:   *** #{this_object_class} association: \'#{association}\', gives a NoMethodError when accessed (product bug?) ***")
          end
        end
        $evm.log("info", "#{indent_string}#{@method}:   --- end of associations ---")
      else
        $evm.log("info", "#{indent_string}#{@method}:   #{object_string} has no associations")
      end
    end
  rescue => err
    $evm.log("error", "#{@method} (dump_associations) - [#{err}]\n#{err.backtrace.join("\n")}")
  end
end

# End of dump_associations
#-------------------------------------------------------------------------------------------------------------


#-------------------------------------------------------------------------------------------------------------
# Method:       dump_methods
# Purpose:      Dumps the methods (if any) of the object class passed to it
# Arguments:    object_string     : friendly text string name for the object
#               this_object       : the Ruby object whose methods are to be dumped
#               indent_string     : the string to use to indent the output (represents recursion depth)
# Returns:      None
#-------------------------------------------------------------------------------------------------------------

def dump_methods(object_string, this_object, indent_string)
  begin
    #
    # Only dump the methods of an MiqAeMethodService::* class
    #
    if this_object.method_missing(:class).to_s =~ /^MiqAeMethodService.*/
      $evm.log("info", "#{indent_string}#{@method}:   Class of remote DRb::DRbObject is: #{this_object.method_missing(:class)}") if @debug
      #
      # Get the instance methods of the class and convert to string
      #
      if this_object.method_missing(:class).respond_to?(:instance_methods)
        instance_methods = this_object.method_missing(:class).instance_methods.map { |x| x.to_s }
        #
        # Now we need to remove method names that we're not interested in...
        #
        # ...attribute names...
        #
        attributes = []
        if this_object.respond_to?(:attributes)
          if this_object.attributes.respond_to? :each
            this_object.attributes.each do |key, value|
              attributes << key
            end
          end
        end
        attributes << "attributes"
        $evm.log("info", "Removing attributes: #{instance_methods & attributes}") if @debug
        instance_methods = instance_methods - attributes
        #
        # ...association names...
        #
        associations = []
        if this_object.respond_to?(:associations)
          associations = Array(this_object.associations)
        end
        associations << "associations"
        $evm.log("info", "Removing associations: #{instance_methods & associations}") if @debug
        instance_methods = instance_methods - associations
        #
        # ...virtual column names...
        #
        virtual_column_names = []
        virtual_column_names = this_object.method_missing(:virtual_column_names)
        virtual_column_names << "virtual_column_names"
        $evm.log("info", "Removing virtual_column_names: #{instance_methods & virtual_column_names}") if @debug
        instance_methods = instance_methods - virtual_column_names
        #
        # ... MiqAeServiceModelBase methods ...
        #
        $evm.log("info", "Removing MiqAeServiceModelBase methods: #{instance_methods & @service_mode_base_instance_methods}") if @debug
        instance_methods = instance_methods - @service_mode_base_instance_methods
        #
        # and finally dump out the remainder
        #
        $evm.log("info", "#{indent_string}#{@method}:   --- methods follow ---")
        instance_methods.sort.each do | instance_method |
          $evm.log("info", "#{indent_string}#{@method}:   #{object_string}.#{instance_method}")
        end
        $evm.log("info", "#{indent_string}#{@method}:   --- end of methods ---")
      else
        $evm.log("info", "#{indent_string}#{@method}:   #{object_string} has no instance methods")
      end
    end
  rescue => err
    $evm.log("error", "#{@method} (dump_methods) - [#{err}]\n#{err.backtrace.join("\n")}")
  end
end
# End of dump_methods
#-------------------------------------------------------------------------------------------------------------


#-------------------------------------------------------------------------------------------------------------
# Method:       dump_object
# Purpose:      Dumps the object passed to it
# Arguments:    object_string : friendly text string name for the object
#               this_object   : the Ruby object to be dumped
#               indent_string     : the string to use to indent the output (represents recursion depth)
# Returns:      None
#-------------------------------------------------------------------------------------------------------------

def dump_object(object_string, this_object, indent_string)
  begin
    if @recursion_level == 0
      indent_string += "     "
    else
      indent_string += "|    "
    end
    #
    # Make sure that we don't exceed our maximum recursion level
    #
    @recursion_level += 1
    if @recursion_level > MAX_RECURSION_LEVEL
      $evm.log("info", "#{indent_string}#{@method}:   *** exceeded maximum recursion level ***")
      @recursion_level -= 1
      return
    end
    #
    # Make sure we haven't dumped this object already (some data structure links are cyclical)
    #
    this_object_id = this_object.id.to_s rescue this_object.object_id.to_s
    $evm.log("info", "#{indent_string}#{@method}:   Debug: this_object.method_missing(:class) = #{this_object.method_missing(:class)}") if @debug
    this_object_class = "#{this_object.method_missing(:class)}".demodulize
    $evm.log("info", "#{indent_string}#{@method}:   Debug: this_object_class = #{this_object_class}") if @debug
    if @object_recorder.key?(this_object_class)
      if @object_recorder[this_object_class].include?(this_object_id)
        $evm.log("info", "#{indent_string}#{@method}:   Object #{this_object_class} with ID #{this_object_id} has already been dumped...")
        @recursion_level -= 1
        return
      else
        @object_recorder[this_object_class] << this_object_id
      end
    else
      @object_recorder[this_object_class] = []
      @object_recorder[this_object_class] << this_object_id
    end
    
    #$evm.log("info", "#{indent_string}#{@method}:   Dumping $evm.root") if @recursion_level == 1
    #
    # Dump out the things of interest
    #
    dump_attributes(object_string, this_object, indent_string)
    dump_virtual_columns(object_string, this_object, this_object_class, indent_string)
    dump_associations(object_string, this_object, this_object_class, indent_string)
    dump_methods(object_string, this_object, indent_string) if @dump_methods
  
    @recursion_level -= 1
  rescue => err
    $evm.log("error", "#{@method} (dump_object) - [#{err}]\n#{err.backtrace.join("\n")}")
  end
end

# End of dump_object
#-------------------------------------------------------------------------------------------------------------

# -------------------------------------------- Start of main code --------------------------------------------

$evm.log("info", "#{@method} #{VERSION} - EVM Automate Method Started")

if @dump_methods
  #
  # If we're dumping object methods, then we need to find out the methods of the MiqAeMethodService::MiqAeServiceModelBase class
  # so that we can subtract them from the method list returned from each object. We know that MiqAeServiceModelBase is the superclass
  # of MiqAeMethodService::MiqAeServiceUser, so we can get what we're after via $evm.root['user']
  #
  user = $evm.root['user'] rescue nil
  unless user.nil?
    if user.method_missing(:class).superclass.name == "MiqAeMethodService::MiqAeServiceModelBase"
      @service_mode_base_instance_methods = user.method_missing(:class).superclass.instance_methods.map { |x| x.to_s }
    else
      $evm.log("error", "#{@method} Unexpected parent class of $evm.root['user']: #{user.method_missing(:class).superclass.name}")
      @dump_methods = false
    end
  else
    $evm.log("error", "#{@method} $evm.root['user'] doesn't exist")
    @dump_methods = false
  end
end
#
# Start with some $evm.current attributes
#
$evm.log("info", "     #{@method}:   $evm.current_namespace = #{$evm.current_namespace}   #{type($evm.current_namespace)}")
$evm.log("info", "     #{@method}:   $evm.current_class = #{$evm.current_class}   #{type($evm.current_class)}")
$evm.log("info", "     #{@method}:   $evm.current_instance = #{$evm.current_instance}   #{type($evm.current_instance)}")
$evm.log("info", "     #{@method}:   $evm.current_message = #{$evm.current_message}   #{type($evm.current_message)}")
$evm.log("info", "     #{@method}:   $evm.current_object = #{$evm.current_object}   #{type($evm.current_object)}")
$evm.log("info", "     #{@method}:   $evm.current_object.current_field_name = #{$evm.current_object.current_field_name}   #{type($evm.current_object.current_field_name)}")
$evm.log("info", "     #{@method}:   $evm.current_object.current_field_type = #{$evm.current_object.current_field_type}   #{type($evm.current_object.current_field_type)}")
$evm.log("info", "     #{@method}:   $evm.current_method = #{$evm.current_method}   #{type($evm.current_method)}")
#
# and now dump $evm.root...
#
$evm.log("info", "     #{@method}:   $evm.root = #{$evm.root}   #{type($evm.root)}")
dump_object("$evm.root", $evm.root, "")
#
# then dump $evm.object...
#
$evm.log("info", "     #{@method}:   $evm.object = #{$evm.object}   #{type($evm.object)}")
dump_object("$evm.object", $evm.object, "")
#
# and finally our parent object (if one exists)...
#
$evm.log("info", "     #{@method}:   $evm.parent = #{$evm.parent}   #{type($evm.parent)}")
unless $evm.parent.nil?
  dump_object("$evm.parent", $evm.parent, "")
end
#
# Exit method
#
$evm.log("info", "#{@method} - EVM Automate Method Ended")
exit MIQ_OK
