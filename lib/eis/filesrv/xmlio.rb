require "rexml/document"

module EIS
  class XMLIO
    def initialize elf, tbls, perm_man, svc_hub, fpath
      raise ArgumentError.new("fpath", "fpath must be set.") if fpath.nil?
      @elf = elf
      @tbls = tbls
      @permission_man = perm_man
      @path = fpath
      @svc_hub = svc_hub
    end

    ##
    # Recursive saving routine
    # = Parameters
    # +xml+:: The xml node used by _REXML::Document_
    # +val+:: Value that should be write
    def do_save(xml, val)
      i = 0
      return nil if val.data.nil?

      val.each_data do |e|
        entry = xml.add_element(e.class.to_s, {"index" => i.to_s})
        i += 1
        e.fields.each do |k, v|
          f = entry.add_element(k)
          if v.instance_of?(Ref)
            f.add_attribute("type", "Ref")
            f.add_attribute("refval", v.ref.to_s(16).upcase)
            f.add_attribute("limiter", v.limiter.to_s)

            # puts v.data
            if v.data.type == :single && v.data.ref_cnt == 1
              do_save(f, v.data.table)
              f.add_attribute("embed", "true")
              f.add_attribute("base", v.data.table.type.to_s)
            else
              f.add_attribute("refname", v.data.name)
              f.add_attribute("embed", "false")
            end
          elsif v.data.instance_of?(Array)
            f.add_attribute("type", "Array")
            f.add_attribute("size", v.data.size.to_s)
            f.add_attribute("base", v.class.to_s)
            v.data.each do |entry1|
              f.add_element("entry").add_text(entry1.to_s)
            end
          elsif v.instance_of?(EIS::String)
            f.add_attribute("type", "String")
            f.add_attribute("refval", v.ref.to_s(16).upcase)
            f.add_text(v.data.to_s)
            # f.add_attribute("movable", v.shiftable.to_s)
          else
            # f.add_attribute("type", v.class.to_s)
            f.add_text(v.data.to_s) # TODO: escape here
          end
        end
      end
    end

    ##
    # Save data to file.
    def save
      file = File.new @path, "w"
      doc = REXML::Document.new
      xml = doc.add_element("ELF", {"name" => @elf.base_stream.path, "version" => @elf.base_stream.mtime.to_s}) # root element

      @tbls.each_primary do |value| # save all tables
        ele = xml.add_element(value.name,
          {"type" => "PrimaryTable",
           "addr" => value.table.location.to_s(16),
           "size" => value.table.count.to_s,
           "base" => value.table.type.to_s})

        do_save(ele, value.table)
      end

      @tbls.each_single do |cell|
        next if cell.ref_cnt == 1
        ele = xml.add_element(cell.name,
          {"type" => "MultiRefedTable",
           "addr" => cell.table.location.to_s(16),
           "size" => cell.table.count.to_s,
           "base" => cell.table.type.to_s})

        do_save(ele, cell.table)
      end

      # save permission data
      pm = xml.add_element("PermissiveBlocks", {"type" => "PermBlkGrp", "count" => @permission_man.register_table.size})
      @permission_man.register_table.each do |e|
        entry = pm.add_element("PermissiveBlock")
        entry.add_attribute("location", e.location.to_s(16))
        entry.add_attribute("length", e.length.to_s(10))
        # entry.add_element("Location", {"base" => "16", "unit" => "byte"}).add_text(e.location.to_s(16))
        # entry.add_element("Length", {"base" => "10", "unit" => "byte"}).add_text(e.length.to_s)
      end

      doc.write file, 2
      file.close
    end

    def do_tblload(xmlele, tbl)
      data = Hash.new nil
      xmlele.elements.each do |e| # entries in table
        cnt = Module.const_get(e.name).new(@svc_hub) # new instance of Type

        postpondread = []

        e.elements.each do |fld| # every fileds
          if fld.attributes["type"] == "Array"
            tmp = []
            fld.each_element do |entry|
              if fld["base"].include? "Int"
                textarr = entry.text.split ", "
                textarr.each do |datum|
                  tmp << datum.to_i
                end
              else
                raise "FIXME: Not Implemented Yet"
              end
            end
            cnt.send("#{fld.name}=", tmp) # TODO: de-escape here
          elsif fld.attributes["type"] == "Ref"
            if fld.attributes["embed"] == "false"
              cnt.send("#{fld.name}=", @tbls.cell_by_id!(fld["refname"].strip))
            elsif fld.attributes["embed"] == "true"
              postpondread << fld
              # Because not all information that we need is read at this moment.
              # We postpond this element for last to read.

              # tid = @tbls.get_id!(fld["refval"].to_i(16), # This is the value of the vma
              #   Module.const_get(fld["base"]), # Get the corresponding type
              #   )
              # cnt.send("#{fld.name}=", @tbls.cell_by_id(tid))
            else
              raise "'embed' attribute violate. Value can't be '#{fld.attributes["embed"]}'"
              # raise "属性值 'embed' 违约。"
            end
          elsif fld.attributes["type"] == "String"
            cnt.fields[fld.name].ref = fld.attributes["refval"].strip.to_i(16)
            cnt.send("#{fld.name}=", fld.text.strip)
          else
            cnt.send("#{fld.name}=", fld.text.strip) # TODO: de-escape here
          end
        end
        # For now every data that we have is read in.
        # Start to read the postponded table(s).
        until postpondread.empty?
          txt = postpondread.pop
          # Get limiter information
          limiter = txt["limiter"]
          # Is integer
          count = if (limiter.chr >= "0" && limiter.chr <= "9") || limiter.chr == "-"
            limiter.to_i
          else
            cnt.send(limiter) # at here, limiter is the field's name.
          end

          # At here, we can use ref_get_id! because it will create table automatically,
          # and the table created by ref_get_id! is :single, which just as we want.
          # Moreover, if the tablse has existed already, this method will return
          # the id directly.
          # Remember! This method just called to CREATE the table, the table reachs
          # here should ALWAYS be :single!!
          id = @tbls.ref_get_id!(
            txt["refval"].to_i(16), # This is the vma, so is_vma is not need to set
            Module.const_get(txt["base"]),
            count
          )

          tbl = @tbls.table_by_id id
          do_tblload(txt, tbl)
          cnt.send("#{txt.name}=", @tbls.cell_by_id(id)) # TODO: de-escape here
        end

        data[e["index"]] = cnt
      end
      tbl.update_data! data
    end

    def load(strict)
      doc = REXML::Document.new(File.new(@path, "r"))

      root = doc.root
      if root.attributes["version"] != @elf.base_stream.mtime.to_s # base elf version mismatch
        warn "WARN: The version of elf against the version of knowledge base"
        return nil if strict
      end

      if root.attributes["name"] != @elf.base_stream.path
        warn "WARN: Filenames mismatch."
        return nil if strict
      end

      root.each_element_with_attribute("type", "PermBlkGrp") do |ele|
        ele.each_element do |pm|
          @permission_man.register(pm["location"].to_i(16), pm["length"].to_i(10), align: 1)
        end
        @permission_man.global_merge
      end

      # 为了解引用正常，必须首先声明。
      root.each_element_with_attribute("type", "MultiRefedTable") do |ele|
        tbl = @tbls.table_by_id(ele.name) # Codes is first.
        if tbl.nil?
          @tbls.register_table(
            tbl = Table.new(
              ele["addr"].to_i(16),
              ele["size"].to_i,
              Module.const_get(ele["base"]),
              @elf, is_vma: false
            ), ele.name
          )
        end

        do_tblload(ele, tbl)
      end

      root.each_element_with_attribute("type", "PrimaryTable") do |ele| # load for tables
        tbl = @tbls.table_by_id(ele.name) # Codes is first.
        if tbl.nil?
          @tbls.register_table(
            tbl = Table.new(
              ele["location"].to_i(16),
              ele["size"].to_i,
              Module.const_get(ele["base"]),
              @elf, is_vma: false
            ), ele.name
          )
        end

        do_tblload(ele, tbl)
      end
    end
  end
end
