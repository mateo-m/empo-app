# Plays a game from the inside, for the game-process memory tests.
# mkxp-z runs it as a preload script, PSDK as the prelude, so it runs
# before the game's own scripts. It must parse on Ruby 1.8.
#
# Each frame it presses keys through Input and moves through steps:
# start the game, walk, talk to someone, enter other maps, fight a
# battle, open the menu. It writes each step to autoplay-<pid>.log
# next to this file.

module EmpoAutoplay
  INTERIOR = /house|home|maison|casa|haus|room|center|centre|mart|shop|lab|inn|gym|inside|interior|1f|2f|b1f/i
  OUTDOOR = /route|town|city|ville|road|forest|cave|island|village|path|bourg|chemin/i

  @frame = 0
  @down = {}
  @trig = {}
  @cool = {}
  @policy = :mash
  @busy = false
  @steps = nil
  @step = 0
  @phase = :start
  @ran_at = Time.now
  @installed = nil
  @hooks = 0

  class << self
    attr_reader :ran_at

    def log(text)
      @log ||= begin
        dir = ENV['EMPO_AUTOPLAY'] ? File.dirname(ENV['EMPO_AUTOPLAY']) : '.'
        f = File.open(File.join(dir, "autoplay-#{Process.pid}.log"), 'a')
        f.sync = true
        f
      end
      @log.puts("#{Time.now.to_i} [autoplay] #{text}")
    rescue Exception
    end

    # Keys ---------------------------------------------------------------

    def tap(key, frames = 3)
      return if @down[key] || (@cool[key] || 0) > @frame
      @down[key] = frames
      @trig[key] = true
      @cool[key] = @frame + frames + 6
    end

    def hold(key, frames)
      @trig[key] = true unless @down[key]
      @down[key] = frames
    end

    def names(key)
      return [key] unless key == :C && @family == :psdk
      [:A]
    end

    def match(k, key)
      names(key).each do |n|
        return true if k == n
        return true if Input.const_defined?(n) && Input.const_get(n) == k
      end
      false
    rescue Exception
      false
    end

    def fake(k, trigger)
      (trigger ? @trig : @down).each_key { |key| return true if match(k, key) }
      false
    end

    def fake_dir
      return 2 if @down[:DOWN]
      return 4 if @down[:LEFT]
      return 6 if @down[:RIGHT]
      return 8 if @down[:UP]
      0
    end

    def install_input
      return if @installed && Input.method(:trigger?) == @installed
      @hooks += 1
      n = @hooks
      Input.instance_eval do
        class << self; self; end.class_eval do
          alias_method("empo_press_#{n}", :press?)
          alias_method("empo_trigger_#{n}", :trigger?)
          alias_method("empo_repeat_#{n}", :repeat?)
          define_method(:press?) { |k| EmpoAutoplay.fake(k, false) || send("empo_press_#{n}", k) }
          define_method(:trigger?) { |k| EmpoAutoplay.fake(k, true) || send("empo_trigger_#{n}", k) }
          define_method(:repeat?) { |k| EmpoAutoplay.fake(k, true) || send("empo_repeat_#{n}", k) }
          if method_defined?(:dir4)
            alias_method("empo_dir4_#{n}", :dir4)
            alias_method("empo_dir8_#{n}", :dir8)
            define_method(:dir4) { d = EmpoAutoplay.fake_dir; d == 0 ? send("empo_dir4_#{n}") : d }
            define_method(:dir8) { d = EmpoAutoplay.fake_dir; d == 0 ? send("empo_dir8_#{n}") : d }
          end
        end
      end
      @installed = Input.method(:trigger?)
      log("input hook #{n}")
    end

    def feed
      @frame += 1
      @trig.clear
      @down.keys.each do |k|
        @down[k] -= 1
        @down.delete(k) if @down[k] <= 0
      end
      case @policy
      when :mash then tap(mash_key) if @frame % 20 == 0
      when :back then tap(:B) if @frame % 20 == 0
      when :battle
        if @frame % 600 == 0 && @battle_at
          log("battle still running after #{(Time.now - @battle_at).round}s #{describe}")
        end
        # Back on the map, B opens the pause menu, so the battle keys stop.
        on_map = defined?(Scene_Map) && scene.is_a?(Scene_Map) && @frame - (@map_frame || -99) <= 3
        if @frame % 20 == 0 && on_map
          tap(mash_key)
        elsif @frame % 20 == 0
          @battle_i = (@battle_i || 0) + 1
          tap(BATTLE_KEYS[@battle_i % BATTLE_KEYS.size])
        end
      when :walk
        if @down.empty?
          dirs = [:DOWN, :LEFT, :UP, :RIGHT]
          hold(dirs[(@frame / 50) % 4], 40)
        end
      end
    end

    # Confirm alone cannot leave some screens, such as a list of check
    # boxes with the exit at the bottom. When nothing changes for a
    # while, other keys join in.
    # Each turn: back to the command menu, Fight, move the cursor one
    # slot, then confirm the move and the messages. The four directions
    # in turn visit all four move slots, because the cursor stays where
    # it was. A move with no PP left only costs one turn.
    BATTLE_KEYS = [:B, :B, :C, :RIGHT, :C, :C, :C, :C, :C,
                   :B, :B, :C, :DOWN, :C, :C, :C, :C, :C,
                   :B, :B, :C, :LEFT, :C, :C, :C, :C, :C,
                   :B, :B, :C, :UP, :C, :C, :C, :C, :C]

    # No Back and no Up: on an Essentials map, Back opens the pause menu,
    # and Up from its top reaches "Quit Game".
    STUCK_KEYS = [[:C], [:DOWN, :DOWN, :DOWN, :C], [:C, :LEFT, :C, :RIGHT, :C]]

    def mash_key
      if @frame % 60 == 0
        now = signature
        if now != @last_signature
          @last_signature = now
          @changed_at = Time.now
        end
      end
      stuck = Time.now - (@changed_at || Time.now)
      # On a title or load menu, Down three times can reach "Quit Game".
      # Right only picks "yes" on a yes/no box, such as Uranium's
      # language question, where the cursor starts on "no".
      keys = if defined?(Scene_Map) && scene.is_a?(Scene_Map)
               STUCK_KEYS[stuck < 15 ? 0 : (stuck < 45 ? 1 : 2)]
             else
               stuck < 20 ? [:C] : [:RIGHT, :C]
             end
      @mash_i = (@mash_i || 0) + 1
      keys[@mash_i % keys.size]
    end

    def signature
      i = interpreter
      [scene.class, $game_map && $game_map.map_id, $game_player && [$game_player.x, $game_player.y],
       i && i.instance_variable_get(:@index), $game_temp && $game_temp.respond_to?(:message_text) && $game_temp.message_text]
    rescue Exception
      nil
    end

    # Game state ---------------------------------------------------------

    def scene
      defined?(SceneManager) ? SceneManager.scene : $scene
    end

    def interpreter
      return $game_map.interpreter if $game_map && $game_map.respond_to?(:interpreter)
      return $game_system.map_interpreter if $game_system && $game_system.respond_to?(:map_interpreter)
      nil
    end

    # Essentials runs its pause menu inside Scene_Map#update, so the
    # scene alone does not show that the map is free. A map update that
    # returned in the last frames does.
    def install_map_hook
      return unless defined?(Scene_Map) && Scene_Map.method_defined?(:update)
      return if @map_hook && Scene_Map.instance_method(:update) == @map_hook
      @map_hooks = (@map_hooks || 0) + 1
      n = @map_hooks
      Scene_Map.class_eval do
        alias_method("empo_map_update_#{n}", :update)
        define_method(:update) do |*a|
          r = send("empo_map_update_#{n}", *a)
          EmpoAutoplay.map_updated
          r
        end
      end
      @map_hook = Scene_Map.instance_method(:update)
      log("map hook #{n}")
    end

    def map_updated
      @map_frame = @frame
    end

    def free?
      return false unless defined?(Scene_Map) && scene.is_a?(Scene_Map)
      return false if @frame - (@map_frame || -99) > 3
      i = interpreter
      return false if i && i.running?
      return false if $game_temp && $game_temp.respond_to?(:message_window_showing) && $game_temp.message_window_showing
      return false if $game_temp && $game_temp.respond_to?(:player_transferring) && $game_temp.player_transferring
      return false if defined?($game_message) && $game_message && $game_message.respond_to?(:visible) && $game_message.visible
      return false if $game_player && $game_player.moving?
      true
    rescue Exception
      false
    end

    def describe
      i = interpreter
      "scene=#{scene.class} interp=#{i && i.running?} map=#{$game_map && $game_map.map_id}"
    rescue Exception => e
      "state? #{e.class}"
    end

    def family
      return :psdk if defined?(PFM)
      return :essentials if respond_to?(:pbWildBattle, true) || Object.private_method_defined?(:pbWildBattle) || defined?(WildBattle)
      return :ace if defined?(SceneManager)
      return :vx if defined?(Game_Interpreter)
      :xp
    end

    # Steps --------------------------------------------------------------

    def plan
      maps = pick_maps
      steps = [[:boot]]
      steps << [:walk] << [:talk]
      steps << [:map, maps[0]] << [:walk] << [:talk] if maps[0]
      steps << [:map, maps[1]] << [:walk] << [:talk] if maps[1]
      steps << [:battle] << [:menu]
      steps << [:map, maps[2]] << [:walk] << [:talk] if maps[2]
      steps << [:map, maps[3]] << [:walk] if maps[3]
      steps << [:battle] << [:done]
      steps
    end

    def ext
      { :ace => 'rvdata2', :vx => 'rvdata' }[@family] || 'rxdata'
    end

    def pick_maps
      infos = load_data("Data/MapInfos.#{ext}")
      ids = infos.keys.sort
      inside = []
      outside = []
      ids.each do |id|
        name = infos[id].name.to_s
        inside << id if name =~ INTERIOR
        outside << id if name =~ OUTDOOR
      end
      # Some games change Array methods, so this uses plain loops.
      picks = []
      [[inside, 2], [outside, 4], [ids, 4]].each do |list, most|
        [list.size / 3, (list.size * 2) / 3, list.size / 2, list.size - 1].each do |i|
          id = list[i]
          picks << id if id && picks.size < most && !picks.include?(id)
        end
      end
      text = ''
      picks.each { |id| text << "#{id}:#{infos[id].name} " }
      log("maps #{text}")
      picks
    rescue Exception => e
      log("maps failed #{e.class}: #{e.message} #{(e.backtrace || [])[0, 3].join(' | ')}")
      []
    end

    def start_step(step)
      case step[0]
      when :boot
        @family = family
        log("family #{@family} ruby #{RUBY_VERSION}")
        skip_names
        @policy = :mash
        @limit = 180
      when :walk
        @policy = :walk
        @limit = 5
      when :talk
        @policy = :mash
        @limit = 40
        talk
      when :map
        @policy = :mash
        @limit = 30
        transfer(step[1])
      when :battle
        @policy = :battle
        @limit = 180
        @battle_at = Time.now
        battle
        @battle_at = nil
      when :menu
        @policy = :none
        @limit = 40
        @menu_at = @frame
        menu
      when :done
        @policy = :walk
        @limit = 1_000_000
      end
    end

    def done?(step)
      case step[0]
      when :walk then Time.now - @started > @limit
      when :menu then menu_keys
      when :done then false
      else free_long?
      end
    end

    def free_long?
      if free?
        @free_since ||= @frame
        @frame - @free_since > 90
      else
        @free_since = nil
        false
      end
    end

    def advance
      name_screen
      step = @steps[@step]
      if @phase == :start
        @started = Time.now
        @changed_at = Time.now
        @free_since = nil
        log("step #{@step} #{step.inspect} start #{describe}")
        @phase = :wait
        start_step(step)
      elsif done?(step)
        log("step #{@step} #{step[0]} done after #{(Time.now - @started).round}s")
        next_step
      elsif Time.now - @started > @limit && @phase == :wait
        log("step #{@step} #{step[0]} timeout #{describe}")
        @phase = :recover
        @policy = :back
        @recover_at = Time.now
      elsif @phase == :recover && Time.now - @recover_at > 6
        next_step
      end
    end

    def next_step
      @step += 1 if @step < @steps.size - 1
      @phase = :start
    end

    def run_frame
      @ran_at = Time.now
      # A second hook from the thread below must not count a frame twice.
      count = (Graphics.frame_count rescue nil)
      return if count && count == @count
      @count = count
      feed
      return if @busy
      @busy = true
      begin
        install_input if defined?(Input)
        install_map_hook
        if @steps.nil?
          return unless scene
          @family = family
          @steps = plan
        end
        advance
      rescue Exception => e
        log("error in step #{@step}: #{e.class}: #{e.message} #{(e.backtrace || [])[0, 4].join(' | ')}")
        next_step
      ensure
        @busy = false
      end
    end

    # A method, not a block in the loop below: a while loop has no scope
    # of its own, so each hook would see the name of the last one and
    # call itself.
    def hook_graphics(n)
      name = "empo_autoplay_update_#{n}"
      class << Graphics; self; end.class_eval do
        alias_method name, :update
        define_method(:update) do |*args|
          r = send(name, *args)
          EmpoAutoplay.run_frame
          r
        end
      end
      log("graphics hook #{n}")
    end

    # Actions ------------------------------------------------------------

    def skip_names
      return unless @family == :essentials
      %w(pbEnterPlayerName pbEnterText pbEnterPokemonName pbEnterBoxName pbEnterNPCName pbFreeText).each do |m|
        next unless Object.private_method_defined?(m) || Object.method_defined?(m) || Kernel.respond_to?(m)
        Object.send(:define_method, m) { |*a| 'Test' }
        Object.send(:private, m)
      end
    end

    def name_screen
      return unless scene && scene.class.name == 'Scene_Name'
      log('name screen, leaving it')
      if defined?(SceneManager) then SceneManager.return else $scene = Scene_Map.new end
    end

    def talk
      return log('talk: no map') unless $game_map && $game_player
      talkers = $game_map.events.values.select do |ev|
        list = ev.list rescue nil
        list && list.any? { |c| c.code == 101 }
      end
      if talkers.empty?
        log('talk: nobody here')
        return
      end
      px = $game_player.x
      py = $game_player.y
      ev = talkers.sort_by { |e| (e.x - px).abs + (e.y - py).abs }.first
      log("talk: event #{ev.id} at #{ev.x},#{ev.y}")
      ev.start
    end

    def transfer(id)
      map = load_data(sprintf("Data/Map%03d.#{ext}", id))
      x = map.width / 2
      y = map.height / 2
      if defined?(Yuki::MapLinker)
        x += Yuki::MapLinker.get_OffsetX
        y += Yuki::MapLinker.get_OffsetY
      end
      log("map #{id} at #{x},#{y} size #{map.width}x#{map.height}")
      if $game_player.respond_to?(:reserve_transfer)
        $game_player.reserve_transfer(id, x, y, 2)
      else
        $game_temp.player_new_map_id = id
        $game_temp.player_new_x = x
        $game_temp.player_new_y = y
        $game_temp.player_new_direction = 2
        $game_temp.player_transferring = true
      end
    end

    def first_troop
      $data_troops.each_with_index { |t, i| return i if t && t.members && !t.members.empty? }
      1
    end

    def battle
      case @family
      when :essentials then essentials_battle
      when :psdk
        i = $game_system.map_interpreter
        if $actors.size < 6
          # Some games cap the level below 100 (Edelweiss).
          [100, 70, 50].find { |lv| (i.add_pokemon(1, lv); true) rescue false }
          $actors.unshift($actors.pop)
          tackle_only($actors[0])
        end
        i.call_battle_wild(1, 3)
      when :ace
        $game_party.add_actor(1) if $game_party.members.empty?
        BattleManager.setup(first_troop, true, true)
        BattleManager.play_battle_bgm
        SceneManager.call(Scene_Battle)
      when :vx
        $game_party.add_actor(1) if $game_party.members.empty?
        $game_troop.setup(first_troop)
        $game_troop.can_escape = true
        $game_temp.battle_proc = nil
        $game_temp.next_scene = 'battle'
      else
        $game_party.add_actor(1) if $game_party.actors.empty?
        $game_temp.battle_troop_id = first_troop
        $game_temp.battle_can_escape = true
        $game_temp.battle_can_lose = true
        $game_temp.battle_proc = nil
        $game_temp.battle_calling = true
      end
      log("battle started #{describe}")
    end

    def species
      if defined?(GameData) && defined?(GameData::Species)
        GameData::Species.each { |s| return s.id }
      end
      1
    end

    # A level 100 Pokémon can know only moves that fail, such as Growth.
    # Tackle in every slot makes any move choice end the battle.
    def tackle_only(pk)
      moves = if defined?(PFM::Skill)
                pk.skills_set
              else
                pk.moves
              end
      4.times do |i|
        moves[i] = if defined?(PFM::Skill) then PFM::Skill.new(:tackle)
                   elsif defined?(Pokemon::Move) then Pokemon::Move.new(:TACKLE)
                   else PBMove.new(getID(PBMoves, :TACKLE))
                   end
      end
      log('lead knows only Tackle')
    rescue Exception => e
      log("tackle_only failed #{e.class}: #{e.message}")
    end

    def essentials_battle
      trainer = defined?($player) && $player ? $player : $Trainer
      sp = species
      # A level 100 lead ends the battle in one hit with any damaging move.
      if trainer && trainer.party.size < 6
        pbAddPokemonSilent(sp, 100)
        trainer.party.unshift(trainer.party.pop)
        tackle_only(trainer.party[0])
        log("gave #{sp.inspect} level 100 to the party")
      end
      # A wild battle reads the bag, which a game makes only later in
      # its intro (Uranium).
      $PokemonBag ||= PokemonBag.new if defined?(PokemonBag)
      log("wild battle #{sp.inspect}")
      if defined?(WildBattle) && WildBattle.respond_to?(:start)
        WildBattle.start(sp, 3)
      else
        pbWildBattle(sp, 3)
      end
      log('wild battle returned')
    end

    def menu
      case @family
      when :ace
        SceneManager.call(Scene_Menu)
      when :vx
        $game_temp.next_scene = 'menu'
      else
        $game_temp.menu_calling = true
      end
    end

    # Opens the first two entries of the menu, then closes it.
    MENU_KEYS = [[60, :C], [240, :B], [300, :DOWN], [330, :C], [510, :B], [570, :B], [630, :B], [700, nil]]

    def menu_keys
      age = @frame - @menu_at
      MENU_KEYS.each do |at, key|
        next unless age == at
        return free_long? if key.nil?
        tap(key)
      end
      age > 700 && free_long?
    end
  end
end

module Graphics
  class << self
    alias_method :empo_autoplay_update, :update if method_defined?(:update)
    def update(*args)
      r = respond_to?(:empo_autoplay_update) ? empo_autoplay_update(*args) : nil
      EmpoAutoplay.run_frame
      r
    end
  end
end if defined?(Graphics) && Graphics.respond_to?(:update)

# PSDK and some games define Graphics.update again after this file
# runs, which drops the hook above. This thread puts it back.
Thread.new do
  n = 0
  while n < 5
    sleep 1
    next if Time.now - EmpoAutoplay.ran_at < 3
    next unless defined?(Graphics) && Graphics.respond_to?(:update) && EmpoAutoplay.scene
    n += 1
    EmpoAutoplay.hook_graphics(n)
    sleep 2
  end
end
