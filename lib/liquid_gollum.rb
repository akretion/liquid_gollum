require 'locomotive_liquid'
require 'gollum'

module LiquidGollum
  class InheritBlock < Solid::Block
    tag_name :inherit
    context_attribute :gollum_path
    context_attribute :wiki_options

    def display(*values)
      page_name = values[0]
      if page_name.start_with?('http')
        current_context.stack do
          current_context['format'] = 'xml'
          current_context['scrapping_url'] = page_name
          current_context['scrapping_xpath'] = values && values[1] && values[1][:xpath] || '//body'
          yield
        end
      else
        wiki = Gollum::Wiki.new(gollum_path, wiki_options)
        name = page_name.split("/").last
        path = page_name[0..-(name.size+1)]
        original_page = wiki.paged(name, path, exact = true)
        if values[1] && values[1][:render]
          current_context['render'] = true #TODO only if page format is md?
          original_content = original_page.formatted_data()
        else
          original_content = original_page.raw_data()
        end

        #TODO change image path, check ACL..
        #TODO add from and to keyword to cut original_content optionally
        current_context.stack do
          current_context['original_content'] = original_content
          yield
        end
      end

    end

    def render_all(list, context) #TODO option for not adding \n
      if context['scrapping_url']
        output = Nokogiri::HTML(open(context['scrapping_url'])).xpath(context['scrapping_xpath'])
        output.css("img").each do |img|
          img.attributes["src"].value = "https://doc.openerp.com/#{CGI.escape img.attributes["src"].value}"
        end

        output.css('a.headerlink').each{ |n| n.remove }
      else
        output = context['original_content']
      end
      list.each do |token|
        if token.is_a?(AfterBlock)
          anchor = token.arguments.values[0][0].value
          if context['format'] == 'xml'
            node = output.at_xpath(anchor)
            node.add_next_sibling(token.render(context)) if node
          else
            l = output.split(anchor)
            output.gsub!(/#{anchor}/, "#{anchor}\n#{token.render(context)}")
          end
        elsif token.is_a?(BeforeBlock)
          anchor = token.arguments.values[0][0].value
          l = output.split(anchor)
          output.gsub!(/#{anchor}/, "#{token.render(context)}\n#{anchor}")
        elsif token.is_a?(ReplaceBlock)
          start = token.arguments.values[0][0].value
          final = token.arguments.values[0][1].value
          l = output.split(start)
          l2 = [l[0], l[1].split(final)]
          l3 = [l2[0], "\n#{token.render(context)}\n", l2[1][1]].join() 
          output = l3
        end
      end
      output.to_s
    end
  end

  class AfterBlock < Solid::Block
    tag_name :after
    def display(*values)
      yield
    end
  end

  class BeforeBlock < Solid::Block
    tag_name :before
    def display(*values)
      yield
    end
  end

  class ReplaceBlock < Solid::Block
    tag_name :replace
    def display(*values)
      yield
    end
  end

end