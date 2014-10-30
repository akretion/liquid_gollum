require 'gollum'
require 'solid'
require 'open-uri'
require 'nokogiri'
require 'active_support/cache'


Precious::App.set(:liquid_cache, ActiveSupport::Cache::MemoryStore.new(expires_in: 30.minutes)) #TODO make it configurable

class Gollum::Page
  attr_accessor :show_mode, :scrapping_url, :params
end

module Gollum
#  module LiquidPage
   class Page

    #overriden so we render Liquid templates before processig further to format conversion
    def text_data(encoding=nil)
      if raw_data.respond_to?(:encoding)
        text = raw_data.force_encoding(encoding || Encoding::UTF_8)
      else
        text = raw_data
      end
      if @show_mode # avoids rendering liquid in edit mode
        render_liquid(text)
      else
        text
      end
    end

    def render_liquid(text)
      #Gollum sequence diagrams would conflict with Liquid syntax; escape them temporarily:
      escaped_text = text.gsub("{{{{{{", "LIQ-ESCAPE1").gsub("}}}}}}", "LIQ-ESCAPE2")

      liquid_context = { #NOTE use Drops for lazy loading?
        'page' => {'filename' => filename,
          'title' => title,
          'name' => name,
          'sub_page' => sub_page,
          'url_path' => url_path,
          'format' => format
#          'metadata' => metadata
        },
        'params' => @params,
        'path' => @path,
        'scrapping_url' => scrapping_url,
        'name' => name,
        'wiki_options' => Precious::App.settings.wiki_options,
        'gollum_path' => Precious::App.settings.gollum_path
      }

      tmp_text = Liquid::Template.parse(escaped_text).render(liquid_context)
      tmp_text.gsub("LIQ-ESCAPE1", "{{{{{{").gsub("LIQ-ESCAPE2", "}}}}}}")
    end

    def header
      @header ||= find_sub_page(:header)
      if @header
        @header.show_mode = @show_mode
        @header.params = @params
      end
      @header
    end

    def sidebar
      @sidebar ||= find_sub_page(:sidebar)
      if @sidebar
        @sidebar.show_mode = @show_mode
        @sidebar.params = @params
      end
      @sidebar
    end

    def footer
      @footer ||= find_sub_page(:footer)
      if @footer
        @footer.show_mode = @show_mode
        @footer.params = params
      end
      @footer
    end

  end

end


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
          if values[1]
            current_context['scrapping_xpath'] = values[1][:xpath] || '//body'
            current_context['scrapping_images_root'] = values[1][:images_root]
          end
          yield
        end
      else
        wiki = Gollum::Wiki.new(gollum_path, wiki_options)
        name = page_name.split("/").last
        path = page_name[0..-(name.size+1)]
        original_page = wiki.paged(name, path, exact = true)
        original_page.show_mode = true
        # TODO propagate page params
        if values[1] && values[1][:render]
          current_context['render'] = true #TODO only if page format is md?
          original_content = original_page.formatted_data()
        else
          original_content = original_page.raw_data()
        end
        
        if values[1] #TODO same for xml; use it
          from = values[1][:from]
          to = values[1][:to]
        end

        #TODO change image path, check ACL..
        current_context.stack do
          current_context['original_content'] = original_content
          yield
        end
      end

    end

    def render_all(list, context) #TODO option for not adding \n
      if context['scrapping_url']
        html = Precious::App.liquid_cache.fetch(context['scrapping_url']) do
          open(context['scrapping_url']).read
        end
        doc = Nokogiri::HTML(html)
        output = doc.xpath(context['scrapping_xpath'])

        if context['scrapping_images_root']
          output.css("img").each do |img|
            img.attributes["src"].value = "#{context['scrapping_images_root']}/#{CGI.escape img.attributes["src"].value}"
          end
        end

        output.css("em").each { |em| em.name = 'div'} # else Gollum markup would screw them as cite
        output.css('a.headerlink').each{ |n| n.remove } #TODO abstract in block
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
          if context['format'] == 'xml'
            node = output.at_xpath(anchor)
            node.add_previous_sibling(token.render(context)) if node
          else
            l = output.split(anchor)
            output.gsub!(/#{anchor}/, "#{token.render(context)}\n#{anchor}")
          end
        elsif token.is_a?(ReplaceBlock)
          start = token.arguments.values[0][0].value
          final = token.arguments.values[0][1] && token.arguments.values[0][1].value
          if context['format'] == 'xml'
            if final
              start = output.at_xpath(start)
              final = output.at_xpath(final)
              current = start.next_sibling()
              to_remove = [start]
              while current != final
                to_remove << current
                current = current.next_sibling()
              end
              to_remove.each { |n| n.remove }
              new_node = doc.create_element final.name
              new_node.inner_html = token.render(context)
              final.replace new_node
            else
              node = output.at_xpath(start)
              new_node = doc.create_element node.name
              new_node.inner_html = token.render(context)
              node.replace new_node
            end
          else
            l = output.split(start)
            l2 = [l[0], l[1].split(final)]
            output = [l2[0], "\n#{token.render(context)}\n", l2[1][1]].join() 
          end
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
