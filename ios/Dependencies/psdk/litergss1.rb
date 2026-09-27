# PSDK games from December 2019 to about March 2021 call LiteRGSS 1. That
# version drew through LiteRGSS::Graphics, read keys through LiteRGSS::Input
# and LiteRGSS::Mouse, and let a Viewport, a Sprite or a Text exist without a
# window. LiteRGSS 2 has none of that, so this file puts it back on top of
# LiteRGSS 2.
module LiteRGSS
  module Graphics
    StoppedError = DisplayWindow::StoppedError
    ClosedWindowError = DisplayWindow::ClosedWindowError

    # LiteRGSS 1 fades the frozen frame out through the transition bitmap
    # with this shader.
    TRANSITION_SHADER = <<~GLSL
      uniform float param;
      uniform sampler2D texture;
      uniform sampler2D transition;
      const float sensibilite = 0.05;
      const float scale = 1.0 + sensibilite;
      void main()
      {
        vec4 frag = texture2D(texture, gl_TexCoord[0].xy);
        vec4 tran = texture2D(transition, gl_TexCoord[0].xy);
        float pixel = max(max(tran.r, tran.g), tran.b);
        pixel -= (param * scale);
        if(pixel < sensibilite)
        {
          frag.a = max(0.0, sensibilite + pixel / sensibilite);
        }
        gl_FragColor = frag;
      }
    GLSL

    @psdk_frame_count = 0
    @psdk_viewports = []
    @psdk_speed = 1
    @__elementtable = []
    # The prelude's frame_rate patch is for the FPSBalancer of later PSDK
    # releases. These games pace themselves with the Graphics::DT constants
    # instead, and psdk_prepare_frame sets those.
    @psdk_fast_forward_patch = true

    class << self
      attr_reader :psdk_viewports

      def start
        return if @psdk_window

        @psdk_window = DisplayWindow.new(
          psdk_config(:Title, 'PSDK').to_s, psdk_config(:ScreenWidth, 320), psdk_config(:ScreenHeight, 240),
          psdk_config(:ScreenScale, 1).to_f, 32, psdk_config(:FrameRate, 60), psdk_config(:Vsync, true),
          psdk_config(:FullScreen, false), true
        )
        @psdk_window.on_closed = proc { @on_close ? @on_close.call : true }
        Input.psdk_listen(@psdk_window)
        Mouse.psdk_listen(@psdk_window)
      end

      def stop
        raise StoppedError, 'Graphics is already stopped' unless @psdk_window

        @psdk_window.dispose
        @psdk_window = nil
      end

      def psdk_window
        @psdk_window || raise(StoppedError, 'Graphics is not started')
      end

      # The game replaces update with its own, which calls this one, so
      # transition calls psdk_update to skip the game's frame balancer.
      def psdk_update
        psdk_prepare_frame
        Input.psdk_text = nil
        psdk_window.update
        @psdk_frame_count += 1
      end
      alias update psdk_update

      def update_no_input
        psdk_prepare_frame
        psdk_window.update_no_input
      end

      def update_only_input
        Input.psdk_text = nil
        psdk_window.update_only_input
      end

      def frame_count
        @psdk_frame_count
      end

      def frame_count=(value)
        @psdk_frame_count = value
      end

      def freeze
        psdk_dispose_frozen
        @psdk_frozen = ShaderedSprite.new(psdk_window)
        @psdk_frozen.bitmap = snap_to_bitmap
        @psdk_frozen.z = 0x7FFFFFFF
        psdk_window.sort_z
      end

      def transition(time = 8, bitmap = nil)
        sprite = @psdk_frozen
        return unless sprite

        time = time.to_i.clamp(1, 0xFFFF)
        if bitmap
          sprite.shader = Shader.new(TRANSITION_SHADER)
          sprite.shader.set_texture_uniform('transition', bitmap)
        end
        1.upto(time) do |i|
          if bitmap
            sprite.shader.set_float_uniform('param', i.fdiv(time))
          else
            sprite.opacity = 255 * (time - i) / time
          end
          psdk_update
        end
      ensure
        psdk_dispose_frozen
      end

      # LiteRGSS 2 draws one viewport at a time into a bitmap, so the screen
      # is those bitmaps put together in z order.
      def snap_to_bitmap
        viewports = @psdk_viewports.reject(&:disposed?).select(&:visible)
        viewports.sort_by! { |viewport| [viewport.z, viewport.__index__] }
        canvas = Viewport.new(psdk_window, 0, 0, width, height)
        bitmaps = viewports.map do |viewport|
          sprite = Sprite.new(canvas)
          sprite.bitmap = viewport.snap_to_bitmap
          sprite.set_position(viewport.rect.x, viewport.rect.y)
          sprite.bitmap
        end
        result = canvas.snap_to_bitmap
        bitmaps.each(&:dispose)
        canvas.dispose
        result
      end

      def list_resolutions
        DisplayWindow.list_resolutions
      end

      def width
        psdk_window.width
      end

      def height
        psdk_window.height
      end

      def reload_stack
        psdk_window.sort_z
      end

      def brightness
        psdk_window.brightness
      end

      def brightness=(value)
        psdk_window.brightness = value
      end

      def shader
        psdk_window.shader
      end

      def shader=(shader)
        psdk_window.shader = shader
      end

      def resize_screen(width, height)
        psdk_window.resize_screen(width, height)
      end

      def openGL_version
        psdk_window.openGL_version
      end

      def psdk_config(name, default)
        Config.const_defined?(name, false) ? Config.const_get(name) : default
      end

      private

      def psdk_prepare_frame
        speed = LiteRGSS.fast_forward_multiplier
        if speed != @psdk_speed && respond_to?(:frame_rate=)
          @psdk_speed = speed
          self.frame_rate = psdk_config(:FrameRate, 60) * speed
        end
        @psdk_viewports.reject!(&:disposed?)
        @psdk_viewports.each(&:psdk_apply_tone_and_color)
      end

      def psdk_dispose_frozen
        return unless @psdk_frozen

        @psdk_frozen.bitmap&.dispose
        @psdk_frozen.dispose
        @psdk_frozen = nil
      end
    end
  end

  module Input
    Keyboard = Sf::Keyboard
    JoyAxisX = Sf::Joystick::X
    JoyAxisY = Sf::Joystick::Y
    JoyAxisZ = Sf::Joystick::Z
    JoyAxisR = Sf::Joystick::R
    JoyAxisU = Sf::Joystick::U
    JoyAxisV = Sf::Joystick::V
    JoyAxisPovX = Sf::Joystick::POV_X
    JoyAxisPovY = Sf::Joystick::POV_Y

    # A negative code is a joystick button: -(32 * joystick) - button - 1.
    Keys = {
      A: [Keyboard::C, Keyboard::Enter, Keyboard::Space, -1],
      B: [Keyboard::X, Keyboard::Escape, Keyboard::LShift, Keyboard::RShift, Keyboard::Backspace, -2],
      X: [Keyboard::V, Keyboard::LAlt, -3],
      Y: [Keyboard::W, Keyboard::RAlt, -4],
      L: [Keyboard::A, -5],
      R: [Keyboard::E, -6],
      L2: [Keyboard::Num1],
      R2: [Keyboard::Num3],
      L3: [],
      R3: [],
      START: [Keyboard::B, -8],
      SELECT: [Keyboard::N, -7],
      HOME: [Keyboard::LControl, Keyboard::RControl],
      UP: [Keyboard::Up, Keyboard::Z, Keyboard::Numpad8],
      DOWN: [Keyboard::Down, Keyboard::S, Keyboard::Numpad2],
      LEFT: [Keyboard::Left, Keyboard::Q, Keyboard::Numpad4],
      RIGHT: [Keyboard::Right, Keyboard::D, Keyboard::Numpad6]
    }
    %i[START SELECT HOME UP DOWN LEFT RIGHT].each { |name| Keys[name.downcase] = Keys[name] }
    Keys.default = Keys[:A]
    # LiteRGSS 1 keeps one state per slot. A key name that the game adds to
    # Keys gets slot 0, the state of A.
    SLOTS = Hash.new(0)
    %i[A B X Y L R L2 R2 L3 R3 START SELECT HOME UP DOWN LEFT RIGHT].each_with_index do |name, slot|
      SLOTS[name] = SLOTS[name.downcase] = slot
    end
    UP_SLOT = SLOTS[:UP]
    DOWN_SLOT = SLOTS[:DOWN]
    LEFT_SLOT = SLOTS[:LEFT]
    RIGHT_SLOT = SLOTS[:RIGHT]
    AXIS_DEAD_ZONE = 25

    @psdk_pressed = Array.new(17, false)
    @psdk_changed_at = Array.new(17, 0)
    @main_joy = 0
    @x_axis = JoyAxisX
    @y_axis = JoyAxisY
    @x_axis_inverted = false
    @y_axis_inverted = false

    class << self
      attr_accessor :main_joy, :x_axis, :y_axis, :x_axis_inverted, :y_axis_inverted
      attr_writer :psdk_text

      def press?(key)
        @psdk_pressed[SLOTS[key]]
      end

      def trigger?(key)
        slot = SLOTS[key]
        @psdk_pressed[slot] && psdk_changed_last_frame?(slot)
      end

      def released?(key)
        slot = SLOTS[key]
        !@psdk_pressed[slot] && psdk_changed_last_frame?(slot)
      end

      # Repeats start half a second after the press, then come 6 times a
      # second, counted in frames at the window's frame rate.
      def repeat?(key)
        slot = SLOTS[key]
        return false unless @psdk_pressed[slot]
        return true if psdk_changed_last_frame?(slot)

        rate = Graphics.psdk_config(:FrameRate, 60)
        count = Graphics.frame_count - @psdk_changed_at[slot]
        count > rate / 2 && ((count - rate / 2) % (rate / 6)).zero?
      end

      def dir4
        return 8 if @psdk_pressed[UP_SLOT]
        return 2 if @psdk_pressed[DOWN_SLOT]
        return 4 if @psdk_pressed[LEFT_SLOT]
        return 6 if @psdk_pressed[RIGHT_SLOT]

        0
      end

      def dir8
        column = @psdk_pressed[LEFT_SLOT] ? 0 : (@psdk_pressed[RIGHT_SLOT] ? 2 : 1)
        return 7 + column if @psdk_pressed[UP_SLOT]
        return 1 + column if @psdk_pressed[DOWN_SLOT]

        [4, 0, 6][column]
      end

      def get_text
        @psdk_text
      end

      def joy_connected?(id)
        Sf::Joystick.connected?(id)
      end

      def joy_button_count(id)
        Sf::Joystick.button_count(id)
      end

      def joy_has_axis?(id, axis)
        Sf::Joystick.axis_available?(id, axis)
      end

      def joy_button_press?(id, button)
        Sf::Joystick.press?(id, button)
      end

      def joy_axis_position(id, axis)
        Sf::Joystick.axis_position(id, axis).to_i
      end

      def joy_name(id)
        Sf::Joystick.identification(id).first
      end

      def psdk_listen(window)
        window.on_key_pressed = proc { |code, *| psdk_code(code, true) }
        window.on_key_released = proc { |code, *| psdk_code(code, false) }
        window.on_joystick_button_pressed = proc { |id, button| psdk_code(-32 * id - button - 1, true) }
        window.on_joystick_button_released = proc { |id, button| psdk_code(-32 * id - button - 1, false) }
        window.on_joystick_moved = proc { |id, axis, position| psdk_axis(id, axis, position) }
        window.on_joystick_connected = proc { |id| psdk_center(id) }
        window.on_joystick_disconnected = proc { |id| psdk_center(id) }
        window.on_text_entered = proc { |text| @psdk_text = @psdk_text ? @psdk_text + text : text.dup }
      end

      private

      def psdk_changed_last_frame?(slot)
        @psdk_changed_at[slot] == Graphics.frame_count - 1
      end

      def psdk_set(slot, pressed)
        return if @psdk_pressed[slot] == pressed

        @psdk_pressed[slot] = pressed
        @psdk_changed_at[slot] = Graphics.frame_count
      end

      def psdk_code(code, pressed)
        Keys.each { |name, codes| psdk_set(SLOTS[name], pressed) if codes.include?(code) }
      end

      def psdk_axis(id, axis, position)
        return unless id == @main_joy

        if axis == @x_axis
          psdk_direction(LEFT_SLOT, RIGHT_SLOT, @x_axis_inverted ? -position : position)
        elsif axis == @y_axis
          psdk_direction(UP_SLOT, DOWN_SLOT, @y_axis_inverted ? -position : position)
        end
      end

      def psdk_direction(low_slot, high_slot, position)
        psdk_set(low_slot, position < -AXIS_DEAD_ZONE)
        psdk_set(high_slot, position > AXIS_DEAD_ZONE)
      end

      def psdk_center(id)
        psdk_axis(id, @x_axis, 0)
        psdk_axis(id, @y_axis, 0)
      end
    end
  end

  module Mouse
    Keys = {
      LEFT: Sf::Mouse::LEFT, left: Sf::Mouse::LEFT,
      RIGHT: Sf::Mouse::RIGHT, right: Sf::Mouse::RIGHT,
      MIDDLE: Sf::Mouse::Middle, middle: Sf::Mouse::Middle,
      X1: Sf::Mouse::XButton1, x1: Sf::Mouse::XButton1,
      X2: Sf::Mouse::XButton2, x2: Sf::Mouse::XButton2
    }
    Keys.default = Sf::Mouse::LEFT

    @psdk_pressed = Array.new(5, false)
    @psdk_changed_at = Array.new(5, 0)
    @psdk_x = @psdk_y = -256
    @psdk_wheel = 0

    class << self
      def press?(key)
        @psdk_pressed[Keys[key]]
      end

      def trigger?(key)
        button = Keys[key]
        @psdk_pressed[button] && @psdk_changed_at[button] == Graphics.frame_count - 1
      end

      def released?(key)
        button = Keys[key]
        !@psdk_pressed[button] && @psdk_changed_at[button] == Graphics.frame_count - 1
      end

      def x
        (@psdk_x / Graphics.psdk_config(:ScreenScale, 1)).to_i
      end

      def y
        (@psdk_y / Graphics.psdk_config(:ScreenScale, 1)).to_i
      end

      def wheel
        @psdk_wheel
      end

      def wheel=(value)
        @psdk_wheel = value
      end

      def psdk_listen(window)
        window.on_mouse_moved = proc { |x, y| psdk_move(x, y) }
        window.on_mouse_left = proc { psdk_move(-256, -256) }
        window.on_mouse_button_pressed = proc { |button| psdk_button(button, true) }
        window.on_mouse_button_released = proc { |button| psdk_button(button, false) }
        window.on_mouse_wheel_scrolled = proc do |wheel, delta|
          @psdk_wheel += delta.to_i if wheel == Sf::Mouse::VerticalWheel
        end
      end

      private

      def psdk_move(x, y)
        @psdk_x = x < 0 ? -256 : x
        @psdk_y = y
      end

      def psdk_button(button, pressed)
        return unless button.between?(0, 4) && @psdk_pressed[button] != pressed

        @psdk_pressed[button] = pressed
        @psdk_changed_at[button] = Graphics.frame_count
      end
    end
  end

  class Viewport
    # LiteRGSS 1 gives every viewport a tone and a color. LiteRGSS 2 has
    # neither, so a viewport gets this shader once the game touches one.
    TONE_AND_COLOR_SHADER = <<~GLSL
      uniform sampler2D texture;
      uniform vec4 tone;
      uniform vec4 color;
      const vec3 lumaF = vec3(.299, .587, .114);
      void main()
      {
        vec4 frag = texture2D(texture, gl_TexCoord[0].xy);
        frag.rgb = mix(frag.rgb, color.rgb, color.a);
        float luma = dot(frag.rgb, lumaF);
        frag.rgb += tone.rgb;
        frag.rgb = mix(frag.rgb, vec3(luma), tone.w);
        frag.a *= gl_Color.a;
        gl_FragColor = frag;
      }
    GLSL

    module OnWindow
      def initialize(*args)
        args.unshift(Graphics.psdk_window) unless args.first.is_a?(DisplayWindow)
        super(*args)
        @__elementtable = []
        Graphics.psdk_viewports << self
      end
    end
    prepend OnWindow

    # The games replace sort_z with a Ruby sort of @__elementtable, then
    # call reload_stack, as LiteRGSS 1 wanted. Here the native sort does
    # the work.
    alias psdk_sort_z sort_z

    def reload_stack
      psdk_sort_z
    end

    # The games change these in place (color.alpha -= 9), so the setters
    # copy into the same object. Release 24.87 undefines all four and
    # brings its own, which is why they live in the class and not in
    # OnWindow.
    def color
      @psdk_color ||= Color.new(0, 0, 0, 0)
    end

    def color=(value)
      color.set(value.red, value.green, value.blue, value.alpha)
    end

    def tone
      @psdk_tone ||= Tone.new(0, 0, 0, 0)
    end

    def tone=(value)
      tone.set(value.red, value.green, value.blue, value.gray)
    end

    def psdk_apply_tone_and_color
      return unless @psdk_color || @psdk_tone

      color = (@psdk_color ||= Color.new(0, 0, 0, 0))
      tone = (@psdk_tone ||= Tone.new(0, 0, 0, 0))
      state = [color.red, color.green, color.blue, color.alpha, tone.red, tone.green, tone.blue, tone.gray]
      return if state == @psdk_state

      @psdk_state = state
      self.shader = Shader.new(TONE_AND_COLOR_SHADER) unless shader
      shader.set_float_uniform('color', color)
      shader.set_float_uniform('tone', tone)
    end
  end

  # A LiteRGSS 1 drawable without a viewport sits on the screen, and its
  # viewport reads nil. In LiteRGSS 2 its parent is the window.
  module OnScreen
    def viewport
      parent = super
      parent.is_a?(DisplayWindow) ? nil : parent
    end
  end

  module OnScreenFirst
    def initialize(viewport = nil, *args)
      super(viewport || Graphics.psdk_window, *args)
    end
  end

  module OnScreenText
    def initialize(font_id, viewport, *args)
      super(font_id, viewport || Graphics.psdk_window, *args)
    end
  end

  [Sprite, Shape, Window, SpriteMap, Text].each { |klass| klass.prepend(OnScreen) }
  [Sprite, Shape, Window].each { |klass| klass.prepend(OnScreenFirst) }
  Text.prepend(OnScreenText)
end

# The prelude and the games open Graphics, Input and Mouse at the top level
# before the game runs `include LiteRGSS`. Without these names they would
# get new, empty modules.
Graphics = LiteRGSS::Graphics
Input = LiteRGSS::Input
Mouse = LiteRGSS::Mouse
