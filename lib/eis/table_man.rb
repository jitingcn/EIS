require "eis/table"

module EIS
  class TableMan
    ##
    # The initializer. Needing parameters:
    # * elf_man: to check the elf statement.
    # * perm_man: to handle the permission block.
    #   (When the system is set to aggressive, realloc the table)
    #
    # And these named parameters:
    # * implicit_prefix: auto-renaming, if an implicit table checked, the table will
    #   be named as the prefix with its address. DEFAULT: "implicit_".
    # * enable_rename: if a named table be registered after imlicit asumming, whether
    #   the table's id will be changed. If so, after that, the outer codes need to
    #   requery the name by a table's unchangable properties. DEFAULT: false.
    #   __WARN__: Neutralized.
    def initialize elf_man, permissive_man, svc_hub, implicit_prefix: "implicit_", enable_rename: false
      @elf_man = elf_man
      @perm_man = permissive_man
      @svc_hub = svc_hub
      @implicit_prefix = implicit_prefix
      @enable_rename = enable_rename
      @tables = []
    end

    def to_s
      <<~EOS
        EIS::TableMan to #{@elf_man}. Implicit prefix is #{@implicit_prefix}
        #{@tables.size} table(s) is managed.
      EOS
    end

    Cell = Struct.new :name, :table, :type, :ref_cnt

    ##
    # = Register a table to manager
    # This method will register a **created** table to the manager. And
    # by default, this table will be primary type (Can't be shifted).
    #
    # == Parameters
    # +table+:: The table needs to be registered. Must be a instance of
    #           +EIS::Table+.
    # +name+:: The name of the table. If not given, the table will be named
    #          with a specified prefix in initialization and its address
    #          automatically.
    # +type+:: *named* The type of the cell. See the following description.
    #          If this argument is set to +:partial+ or +:single+, which
    #          means that table is already referenced by at least one table,
    #          we set the +ref_cnt+ to +1+ instead of +0+.
    #
    # == Description of Type
    # The parameter 'type' can be one of these posssible pre-defined value:
    # * :primary - The table is primary, it can't be shifted to other
    #   address in any case. The primary table's ref_cnt field means nothing
    #   and will not be update unless the whole table is refered.
    # * :partial - The table is a part of a bigger table. Reffered to the
    #   bigger table and will not be handle during address shifting.
    #   Since :partial is not a real table, the table field is it's location.
    # * :single - The table is implicittly reffered by another table and
    #   it's stand-along. It will be shift if the aggressive shifting
    #   option is specified.
    def register_table table, name = nil, type: :primary
      unless table.is_a? Table
        raise ArgumentError.new("table",
          "Must be EIS::Table but #{table.class}!")
      end
      cell = Cell.new(name.nil? ? @implicit_prefix + table.location.to_s(16) : name,
        table,
        type,
        type == :primary ? 0 : 1)
      @tables << cell
    end

    attr_reader :tables

    def each
      if block_given?
        @tables.each do |table|
          yield table
        end
      end
    end

    def each_table
      if block_given?
        @tables.each do |cell|
          yield cell.table
        end
      end
    end

    def each_primary
      if block_given?
        @tables.each do |table|
          next if table.type != :primary
          yield table
        end
      end
    end

    def each_partial
      if block_given?
        @tables.each do |table|
          next if table.type != :partial
          yield table
        end
      end
    end

    def each_single
      if block_given?
        @tables.each do |table|
          next if table.type != :single
          yield table
        end
      end
    end

    def table_by_id id
      @tables.each do |cell|
        return cell.table if cell.name == id
      end
      nil
    end

    def cell_by_id id
      @tables.each do |cell|
        return cell if cell.name == id
      end
      nil
    end

    ##
    # = Force Get a Cell by Given ID
    # Force table manager return a cell by given ID. If the specified
    # ID does not have a corresponding cell in this table manager, the
    # table manager will create a cell whose type is +:partial+.
    #
    # This feature is designed to be used when a field refered a point
    # IN ANOTHER TABLE, so this method will check whether the given
    # ID is in the table manager, and if so, return it directly, or
    # check the id format. If the ID format is not the format of the
    # "partial table", it will return +nil+. Or if the specified table
    # is not exist, it will also return +nil+. If the specified table
    # is exist, it will create a new "partial" cell that points to the
    # corresponding table and return it.
    #
    # == Parameters
    # +id+:: The ID of the cell wanted to get. The id format is
    #        explained in +TableMan#ref_get_id+.
    def cell_by_id! id
      return cell_by_id(id) unless cell_by_id(id).nil?

      idp = id.split ":"
      return nil if idp.size < 2

      return nil if (tbl = table_by_id(idp[0])).nil?
      return nil if (datum = tbl.datum_by_index(idp[1])).nil?
      cell = Cell.new(id, datum.location, :partial, 1)
      @tables << cell
      cell
    end

    def read
      @tables.each do |cell|
        next if cell.type == :partial
        puts "TableMan#read: will read #{cell.name}@#{cell.table.location.to_s(16)}" if EIS::Core.eis_debug
        cell.table.read
      end
    end

    def write
      @tables.each do |cell|
        next if cell.type == :partial
        puts "TableMan#read: will write #{cell.name}:#{cell.table}" if EIS::Core.eis_debug
        cell.table.write
      end
    end

    ##
    # = Try to get the specified refered table
    # Try get a table datum cell. The location, size, and count.
    # The result will be a <tt>EIS::TableMan::Cell</tt> or a nil if not a
    # corresponding table / partial table can be find.
    #
    # If a partial table be the result, the type will be <tt>:partial</tt>
    # and the naming rule is "[Table name]:[Index name]". e.g. "Talk:23".
    # You'd better handle this special case.
    #
    # *This method only check if here is a corresponding record.*
    #
    # *The ref_cnt counter will increse automatically.*
    #
    # == Parameters
    # +location+::  The location of where the table begins.
    # +size+::      The size of a single entry in the table.
    #               If the value is -1, routine will ignore this limitation.
    # +count+::     The count of the entries in the table.
    # +is_vma+::    _named_ if the location is the vma or not.
    #               DEFAULT: true.
    def ref_get_id location, type, count, is_vma: true
      location = is_vma ? @elf_man.vma_to_loc(location) : location

      each_single do |entry| # 为已经登记的隐含表
        if entry.table.location == location &&
            (count == -1 ? true : entry.table.count == count)
          entry.ref_cnt += 1
          return entry.name
        end
      end

      each_partial do |entry| # 乃其他表的引用
        if entry.table == location
          entry.ref_cnt += 1
          return entry.name # partial 的名字在创建时即符合约定
        end
      end

      each_primary do |cell|
        next unless cell.table.type == type # Type mismatch.

        datum = cell.table.datum_by_location(location)
        next if datum.nil? # Nothing is found.
        return cell.name if cell.table.location == location &&
          cell.table.count == count # 必须是显式指定到整个表才是相同。

        # 所有判例确认完毕，到达此处者皆为部分引用。
        # 由于已有的部分引用在上表一定命中，此处的引用一定不存在。
        # 根据约定，这里不做任何处理（理论存在，但无法创建记录单元）。

        # return "#{cell.name}:#{datum.index}"
      end
      nil
    end

    ##
    # = Get or Set a Specified Table at Location
    # This method will try to find a table that match user's requirement,
    # but if failed, this method will try to create a new table that
    # matches the user's requirement. However, if a partial will be
    # created, the +name+ will be neutralized.
    def ref_get_id! location, type, count, name: nil, is_vma: true
      location = is_vma ? @elf_man.vma_to_loc(location) : location
      raise RangeError.new "location out of range." if location.nil?

      tblnm = name.nil? ? @implicit_prefix + location.to_s(16) : name
      id = ref_get_id location, type, count
      return id unless id.nil?

      each_primary do |cell|
        next unless cell.table.type == type

        datum = cell.table.datum_by_location(location)
        next if datum.nil?

        # 对于已经存在的表的完全匹配必然已在 ref_get_id 中命中并返回。
        # 故此处不必判断是否命中全表，到达此处的必然是部分引用。
        # 所以直接创建记录单元并返回 ID
        @tables << Cell.new("#{cell.name}:#{datum.index}", location, :partial, 1)
        return "#{cell.name}:#{datum.index}"
      end
      # 对于到达这里的项，其表一定尚未创建。
      # 故其必为 :single ，创建新的 Table 容纳之，并创建记录单元。
      table = Table.new(location, count, type, @svc_hub, is_vma: false)
      @tables << Cell.new(tblnm, table, :single, 1)
      tblnm
    end
  end
end
