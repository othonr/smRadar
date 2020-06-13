dofile "$SURVIVAL_DATA/Scripts/util.lua"
dofile "$SURVIVAL_DATA/Scripts/game/survival_constants.lua"
dofile( "$SURVIVAL_DATA/Scripts/game/util/Timer.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_camera.lua" )

SurvivalPlayer = class( nil )


local StatsTickRate = 40

local PerSecond = StatsTickRate / 40
local PerMinute = StatsTickRate / ( 40 * 60 )

local FoodRecoveryThreshold = 5 -- Recover hp when food is above this value
local FastFoodRecoveryThreshold = 50 -- Recover hp fast when food is above this value
local HpRecovery = 50 * PerMinute
local FastHpRecovery = 75 * PerMinute
local FoodCostPerHpRecovery = 0.2
local FastFoodCostPerHpRecovery = 0.2

local FoodCostPerStamina = 0.02
local WaterCostPerStamina = 0.1
local SprintStaminaCost = 0.7 / 40 -- Per tick while sprinting
local CarryStaminaCost = 1.4 / 40 -- Per tick while carrying

local FoodLostPerSecond = 100 / 3.5 / 24 / 60
local WaterLostPerSecond = 100 / 2.5 / 24 / 60

local BreathLostPerTick = ( 100 / 60 ) / 40

local FatigueDamageHp = 1 * PerSecond
local FatigueDamageWater = 2 * PerSecond
local FireDamage = 10
local FireDamageCooldown = 40
local DrownDamage = 5
local DrownDamageCooldown = 40
local PoisonDamage = 10
local PoisonDamageCooldown = 40

local RespawnTimeout = 60 * PerSecond
local BaguetteSteps = 9

local StopTumbleTimerTickThreshold = 1.0 * 40 -- Time to keep tumble active after speed is below threshold
local MaxTumbleTimerTickThreshold = 20.0 * 40 -- Maximum time to keep tumble active before timing out
local TumbleResistTickTime = 3.0 * 40 -- Time that the player will resist tumbling after timing out
local MaxTumbleImpulseSpeed = 35
local TumbleImpactImpulseFraction = 0.5
local RecentTumblesTickTimeInterval = 30.0 * 40 -- Time frame to count amount of tumbles in a row
local MaxRecentTumbles = 3

function SurvivalPlayer.server_onCreate( self )
	self.sv = {}
	self.sv.saved = self.storage:load()
	if self.sv.saved == nil then
		self.sv.saved = {}
		self.sv.saved.stats = {
			hp = 100, maxhp = 100,
			food = 100, maxfood = 100,
			water = 100, maxwater = 100,
			breath = 100, maxbreath = 100
		}
		self.sv.saved.isConscious = true
		self.sv.saved.hasRevivalItem = false
		self.sv.saved.isNewPlayer = true
		self.sv.saved.inChemical = false
		self.storage:save( self.sv.saved )
	end
	self:sv_init()
end

function SurvivalPlayer.server_onRefresh( self )
	self:sv_init()
end

function SurvivalPlayer.sv_init( self )
	self.sv.staminaSpend = 0
	self.sv.blocking = false

	self.sv.statsTimer = Timer()
	self.sv.statsTimer:start( StatsTickRate )

	self.sv.damageCooldown = Timer()
	self.sv.damageCooldown:start( 3.0 * 40 )

	self.sv.impactCooldown = Timer()
	self.sv.impactCooldown:start( 3.0 * 40 )

	self.sv.fireDamageCooldown = Timer()
	self.sv.fireDamageCooldown:start()

	self.sv.poisonDamageCooldown = Timer()
	self.sv.poisonDamageCooldown:start()

	self.sv.drownTimer = Timer()
	self.sv.drownTimer:stop()

	self.sv.tumbleReset = Timer()
	self.sv.tumbleReset:start( StopTumbleTimerTickThreshold )

	self.sv.maxTumbleTimer = Timer()
	self.sv.maxTumbleTimer:start( MaxTumbleTimerTickThreshold )

	self.sv.resistTumbleTimer = Timer()
	self.sv.resistTumbleTimer:start( TumbleResistTickTime )
	self.sv.resistTumbleTimer.count = TumbleResistTickTime

	self.sv.recentTumbles = {}

	self.sv.spawnparams = {}

	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.server_onDestroy( self )

	-- TODO: make this work
	self.storage:save( self.sv.saved )
end

function SurvivalPlayer.client_onCreate( self )
	self.cl = {}
	if self.player == sm.localPlayer.getPlayer() then
		self.cl.hud = sm.gui.createSurvivalHudGui()
		self.cl.hud:open()

		--self.cl.hungryEffect = sm.effect.createEffect( "Mechanic - StatusHungry" )
		--self.cl.thirstyEffect = sm.effect.createEffect( "Mechanic - StatusThirsty" )
		--self.cl.underwaterEffect = sm.effect.createEffect( "Mechanic - StatusUnderwater" )
	end

	self:cl_init()
end

function SurvivalPlayer.client_onRefresh( self )
	self:cl_init()

	sm.gui.hideGui( false )
	sm.camera.setCameraState( sm.camera.state.default )
	sm.localPlayer.setLockedControls( false )
end

function SurvivalPlayer.cl_init(self)

	self.useCutsceneCamera = false
	self.progress = 0
	self.nodeIndex = 1
	self.currentCutscene = {}

	self.markerSpot = sm.vec3.new( 0, 0, 0 )
	self.markerTime = 60 * 10 -- 10 minutes
	self.markerTimeLeft = 0

	self.cl.revivalChewCount = 0
end

function SurvivalPlayer.cl_n_onEvent( self, data )

	local function getCharParam()
		if self.player:isMale() then
			return 1
		else
			return 2
		end
	end

	local function playSingleHurtSound( effect, pos, damage )
		local params = {
			["char"] = getCharParam(),
			["damage"] = damage
		}
		sm.effect.playEffect( effect, pos, sm.vec3.zero(), sm.quat.identity(), sm.vec3.one(), params )
	end

	if data.event == "drown" then
		playSingleHurtSound( "Mechanic - HurtDrown", data.pos, data.damage )
	elseif data.event == "fatigue" then
		playSingleHurtSound( "Mechanic - Hurthunger", data.pos, data.damage)
	elseif data.event == "shock" then
		playSingleHurtSound( "Mechanic - Hurtshock", data.pos, data.damage )
	elseif data.event == "impact" then
		playSingleHurtSound( "Mechanic - Hurt", data.pos, data.damage )
	elseif data.event == "fire" then
		playSingleHurtSound( "Mechanic - HurtFire", data.pos, data.damage )
	elseif data.event == "poison" then
		playSingleHurtSound( "Mechanic - Hurtpoision", data.pos, data.damage )
	end
end

function SurvivalPlayer.client_onClientDataUpdate( self, data )
	if sm.localPlayer.getPlayer() == self.player then

		if self.cl.stats == nil then self.cl.stats = data.stats end -- First time copy to avoid nil errors

		if self.cl.hud then
			self.cl.hud:setSliderData( "Health", data.stats.maxhp * 10 + 1, data.stats.hp * 10 )
			self.cl.hud:setSliderData( "Food", data.stats.maxfood * 10 + 1, data.stats.food * 10 )
			self.cl.hud:setSliderData( "Water", data.stats.maxwater * 10 + 1, data.stats.water * 10 )
			self.cl.hud:setSliderData( "Breath", data.stats.maxbreath * 10 + 1, data.stats.breath * 10 )
		end

		if self.cl.hasRevivalItem ~= data.hasRevivalItem then
			self.cl.revivalChewCount = 0
		end

		--if data.stats.breath <= 15 and not self.cl.underwaterEffect:isPlaying() then
		-- self.cl.underwaterEffect:start()
		--elseif data.stats.breath > 15 and not self.cl.underwaterEffect:isPlaying() then
		-- self.cl.underwaterEffect:stop()
		--end
		--if data.stats.food <= 15 and not self.cl.hungryEffect:isPlaying() then
		-- self.cl.hungryEffect:start()
		--elseif data.stats.food > 15 and not self.cl.hungryEffect:isPlaying() then
		-- self.cl.hungryEffect:stop()
		--end
		--if data.stats.water <= 15 and not self.cl.thirstyEffect:isPlaying() then
		-- self.cl.thirstyEffect:start()
		--elseif data.stats.water > 15 and not self.cl.thirstyEffect:isPlaying() then
		-- self.cl.thirstyEffect:stop()
		--end


		if data.stats.food <= 5 and self.cl.stats.food > 5 then
			sm.gui.displayAlertText( "#{ALERT_HUNGER}", 5 )
		end
		if data.stats.water <= 5 and self.cl.stats.water > 5 then
			sm.gui.displayAlertText( "#{ALERT_THIRST}", 5 )
		end

		if data.stats.hp < self.cl.stats.hp and data.stats.breath == 0 then
			sm.gui.displayAlertText( "#{DAMAGE_BREATH}", 1 )
		elseif data.stats.hp < self.cl.stats.hp and data.stats.food == 0 then
			sm.gui.displayAlertText( "#{DAMAGE_HUNGER}", 1 )
		elseif data.stats.hp < self.cl.stats.hp and data.stats.water == 0 then
			sm.gui.displayAlertText( "#{DAMAGE_THIRST}", 1 )
		end

		self.cl.stats = data.stats
		self.cl.isConscious = data.isConscious
		self.cl.hasRevivalItem = data.hasRevivalItem
		self.cl.inChemical = data.inChemical

		sm.localPlayer.setBlockSprinting( data.stats.food == 0 or data.stats.water == 0 )
	end
end

function SurvivalPlayer.client_onUpdate( self, dt )
	if self.player == sm.localPlayer.getPlayer() then
		self:cl_localPlayerUpdate( dt )
	end
end

local CellSize = 64

--NInd edited this function a lot start
function SurvivalPlayer.cl_localPlayerUpdate( self, dt )
	self:cl_updateCamera( dt )
	if self.cl.hud then
		self.cl.hud:setText( "Time", getTimeOfDayString() )
		local character = self.player:getCharacter()
		if character then
			local homeOffset = sm.vec3.new(-2356,-2624,0)--NInd crash site coordinates
			if g_NIndMapData["home"] then homeOffset = g_NIndMapData["home"] end
			local text = "Dir:"
			local direction = character.direction
			local yaw = math.atan2( direction.y, direction.x )
			if math.abs( yaw ) < math.pi * 0.25 then
				text = text.." E"
			elseif math.abs( yaw ) > math.pi * 0.75 then
				text = text.." W"
			elseif yaw >= math.pi * 0.25 then
				text = text.." N"
			else
				text = text.." S"
			end
			text = text .. " Pos: (" .. math.floor( character.worldPosition.x - homeOffset.x )..","..math.floor( character.worldPosition.y - homeOffset.y )..")"
			text = text .. " Cell: (" .. math.floor( character.worldPosition.x  / CellSize )..","..math.floor( character.worldPosition.y  / CellSize )..")"
			self.cl.hud:setText( "NIndMap", text )
		end
		--NInd edited to here end

		-- Update lost items marker
		self.markerTimeLeft = math.max( self.markerTimeLeft - dt, 0 )
		if self.markerTimeLeft > 0 and false then--HACK: Disabled until lua gui is implemented.

			-- Get screen position for marker
			local screenWidth, screenHeight = sm.gui.getScreenSize()
			local panelWidth, panelHeight = self.HUD.backpackMarker.mainPanel:getSize()
			local screenX, screenY = sm.render.getScreenCoordinatesFromWorldPosition( self.markerSpot, screenWidth, screenHeight )

			-- Find direction from camera to marker
			local markerDirection = self.markerSpot - sm.camera.getPosition()
			local distance = markerDirection:length()
			local selectRange = 7.5
			if distance < selectRange then
				-- Remove marker when close enough
				self.markerTimeLeft = 0
			end
			if distance > 0 then
				markerDirection = markerDirection:normalize()
			else
				markerDirection = sm.camera.getDirection()
			end

			-- Show the marker if it's in front of the camera
			if markerDirection:dot( sm.camera.getDirection() ) > 0 then
				self.HUD.backpackMarker.alert:setText( "Lost items " .. math.ceil( distance * 10 ) / 10  )
				self.HUD.backpackMarker.mainPanel:setPosition( screenX - panelWidth / 2, screenY - panelHeight )
				local maxAlpha = 0.9
				local minAlpha = 0.3
				self.HUD.backpackMarker.mainPanel.alpha = math.min( math.max( ( self.markerTimeLeft / self.markerTime ) + minAlpha, minAlpha ), maxAlpha )
				self.HUD.backpackMarker.widget.visible = true
			else
				self.HUD.backpackMarker.widget.visible = false
			end
		else
			--self.HUD.backpackMarker.widget.visible = false
		end
	end

	local character = self.player:getCharacter()
	if character and not self.cl.isConscious then
		local keyBindingText =  sm.gui.getKeyBinding( "Use" )
		if self.cl.hasRevivalItem then
			if self.cl.revivalChewCount < BaguetteSteps then
				-- sm.gui.setInteractionText( "#{INTERACTION_PRESS}", keyBindingText, "to eat ("..self.cl.revivalChewCount.."/10)" )
				sm.gui.setInteractionText( "", keyBindingText, "#{INTERACTION_EAT} ("..self.cl.revivalChewCount.."/10)" )
			else
				sm.gui.setInteractionText( "", keyBindingText, "#{INTERACTION_REVIVE}" )
			end
		else
			sm.gui.setInteractionText( "", keyBindingText, "#{INTERACTION_RESPAWN}" )
		end
	end

	if character and character:isTumbling() then
		if sm.camera.getCameraState() == sm.camera.state.default then
			sm.camera.setCameraState( sm.camera.state.forcedTP )
			self.cl.tumbleCamera = true
		end
	elseif self.cl.tumbleCamera then
		if sm.camera.getCameraState() == sm.camera.state.default then
			self.cl.tumbleCamera = false
		elseif sm.camera.getCameraState() == sm.camera.state.forcedTP then
			sm.camera.setCameraState( sm.camera.state.default )
			self.cl.tumbleCamera = false
		end
	end

	if character and character:isSwimming() and not self.cl.inChemical then
		self:cl_n_fillWater()
	end

end

function SurvivalPlayer.client_onInteract( self, character, state )
	if state == true then
		--self:cl_startCutscene( camera_test )
		--self:cl_startCutscene( camera_test_joint )
		--self:cl_startCutscene( camera_wakeup_ground )
		--self:cl_startCutscene( camera_approach_crash )
		--self:cl_startCutscene( camera_wakeup_crash )
		--self:cl_startCutscene( camera_wakeup_bed )

		if not self.cl.isConscious then
			if self.cl.hasRevivalItem then
				if self.cl.revivalChewCount >= BaguetteSteps then
					self.network:sendToServer( "sv_n_revive" )
				end
				self.cl.revivalChewCount = self.cl.revivalChewCount + 1
				self.network:sendToServer( "sv_onEvent", { type = "character", data = "chew" } )
			else
				self.network:sendToServer( "sv_n_respawn" )
			end
		end
	end
end

function SurvivalPlayer.cl_addLostItemsMarker( self, params )
	self.markerSpot = params.lostItemsPosition
	self.markerTimeLeft = self.markerTime
end

function SurvivalPlayer.server_onFixedUpdate( self, dt )

	if g_survivalDev and not self.sv.saved.isConscious and not self.sv.saved.hasRevivalItem then
		if sm.container.canSpend( self.player:getInventory(), obj_consumable_longsandwich, 1 ) then
			if sm.container.beginTransaction() then
				sm.container.spend( self.player:getInventory(), obj_consumable_longsandwich, 1, true )
				if sm.container.endTransaction() then
					self.sv.saved.hasRevivalItem = true
					self.player:sendCharacterEvent( "baguette" )
					self.network:setClientData( self.sv.saved )
				end
			end
		end
	end

	local character = self.player:getCharacter()
	if character then
		self:sv_updateTumbling()
	end

	-- If respawn failed, restore the character
	if self.sv.respawnTimeoutTimer then
		self.sv.respawnTimeoutTimer:tick()
		if self.sv.respawnTimeoutTimer:done() then
			self:sv_onSpawnCharacter()
		end
	end

	self.sv.damageCooldown:tick()
	self.sv.impactCooldown:tick()
	self.sv.fireDamageCooldown:tick()
	self.sv.poisonDamageCooldown:tick()

	-- Update breathing
	if character then
		if character:isDiving() then
			self.sv.saved.stats.breath = math.max( self.sv.saved.stats.breath - BreathLostPerTick, 0 )
			if self.sv.saved.stats.breath == 0 then
				self.sv.drownTimer:tick()
				if self.sv.drownTimer:done() then
					if self.sv.saved.isConscious then
						print( "'SurvivalPlayer' is drowning!" )
						self:sv_takeDamage( DrownDamage, "drown" )
					end
					self.sv.drownTimer:start( DrownDamageCooldown )
				end
			end
		else
			self.sv.saved.stats.breath = self.sv.saved.stats.maxbreath
			self.sv.drownTimer:start( DrownDamageCooldown )
		end

		-- Spend stamina on sprinting
		if character:isSprinting() then
			self.sv.staminaSpend = self.sv.staminaSpend + SprintStaminaCost
		end

		-- Spend stamina on carrying
		if not self.player:getCarry():isEmpty() then
			self.sv.staminaSpend = self.sv.staminaSpend + CarryStaminaCost
		end
	end

	-- Update stamina, food and water stats
	if character and self.sv.saved.isConscious and not g_godMode then
		self.sv.statsTimer:tick()
		if self.sv.statsTimer:done() then
			self.sv.statsTimer:start( StatsTickRate )

			-- Recover health from food
			if self.sv.saved.stats.food > FoodRecoveryThreshold then
				local fastRecoveryFraction = 0

				-- Fast recovery when food is above fast threshold
				if self.sv.saved.stats.food > FastFoodRecoveryThreshold then
					local recoverableHp = math.min( self.sv.saved.stats.maxhp - self.sv.saved.stats.hp, FastHpRecovery )
					local foodSpend = math.min( recoverableHp * FastFoodCostPerHpRecovery, math.max( self.sv.saved.stats.food - FastFoodRecoveryThreshold, 0 ) )
					local recoveredHp = foodSpend / FastFoodCostPerHpRecovery

					self.sv.saved.stats.hp = math.min( self.sv.saved.stats.hp + recoveredHp, self.sv.saved.stats.maxhp )
					self.sv.saved.stats.food = self.sv.saved.stats.food - foodSpend
					fastRecoveryFraction = ( recoveredHp ) / FastHpRecovery
				end

				-- Normal recovery
				local recoverableHp = math.min( self.sv.saved.stats.maxhp - self.sv.saved.stats.hp, HpRecovery * ( 1 - fastRecoveryFraction ) )
				local foodSpend = math.min( recoverableHp * FoodCostPerHpRecovery, math.max( self.sv.saved.stats.food - FoodRecoveryThreshold, 0 ) )
				local recoveredHp = foodSpend / FoodCostPerHpRecovery

				self.sv.saved.stats.hp = math.min( self.sv.saved.stats.hp + foodSpend / FoodCostPerHpRecovery, self.sv.saved.stats.maxhp )
				self.sv.saved.stats.food = self.sv.saved.stats.food - foodSpend
			end

			-- Spend water and food on stamina usage
			self.sv.saved.stats.water = math.max( self.sv.saved.stats.water - self.sv.staminaSpend * WaterCostPerStamina, 0 )
			self.sv.saved.stats.food = math.max( self.sv.saved.stats.food - self.sv.staminaSpend * FoodCostPerStamina, 0 )
			self.sv.staminaSpend = 0

			-- Decrease food and water with time
			self.sv.saved.stats.food = math.max( self.sv.saved.stats.food - FoodLostPerSecond, 0 )
			self.sv.saved.stats.water = math.max( self.sv.saved.stats.water - WaterLostPerSecond, 0 )

			local fatigueDamageFromHp = false
			if self.sv.saved.stats.food <= 0 then
				self:sv_takeDamage( FatigueDamageHp, "fatigue" )
				fatigueDamageFromHp = true
			end
			if self.sv.saved.stats.water <= 0 then
				if not fatigueDamageFromHp then
					self:sv_takeDamage( FatigueDamageWater, "fatigue" )
				end
			end

			self.storage:save( self.sv.saved )
			self.network:setClientData( self.sv.saved )
		end
	end
end

function SurvivalPlayer.server_onProjectile( self, hitPos, hitTime, hitVelocity, projectileName, attacker, damage )
	if type( attacker ) == "Unit" or ( type( attacker ) == "Shape" and isTrapProjectile( projectileName ) ) then
		self:sv_takeDamage( damage, "shock" )
	end
	if self.player.character:isTumbling() then
		ApplyKnockback( self.player.character, hitVelocity:normalize(), 2000 )
	end

	if projectileName == "water"  then
		self.network:sendToClient( self.player, "cl_n_fillWater" )
	end
end

function SurvivalPlayer.cl_n_fillWater( self )
	if self.player == sm.localPlayer.getPlayer() then
		if sm.localPlayer.getActiveItem() == obj_tool_bucket_empty then
			local params = {}
			params.playerInventory = sm.localPlayer.getInventory()
			params.slotIndex = sm.localPlayer.getSelectedHotbarSlot()
			params.previousUid = obj_tool_bucket_empty
			params.nextUid = obj_tool_bucket_water
			params.previousQuantity = 1
			params.nextQuantity = 1
			self.network:sendToServer( "sv_n_exchangeItem", params )
		end
	end
end

function SurvivalPlayer.sv_updateBlocking( self, blocking )
	self.sv.blocking = blocking
end

function SurvivalPlayer.server_onMelee( self, hitPos, attacker, damage, power )
	if not sm.exists( attacker ) then
		return
	end
	local attackingCharacter = attacker:getCharacter()
	local playerCharacter = self.player:getCharacter()
	if attackingCharacter ~= nil and playerCharacter ~= nil then
		local attackDirection = ( hitPos - attackingCharacter.worldPosition ):normalize()
		local directionDiff = ( attackDirection - playerCharacter:getDirection() ):length()
		local directionDiffThreshold = 1.6
		if directionDiff >= directionDiffThreshold and self.sv.blocking == true then
			print("'SurvivalPlayer' blocked melee damage")
			sm.effect.playEffect( "SledgehammerHit - Default", playerCharacter.worldPosition + sm.vec3.new( 0, 0, 0.5 ) - ( attackDirection - playerCharacter:getDirection() ) * 0.25 )
		else
			print("'SurvivalPlayer' took melee damage")
			if type( attacker ) == "Unit" then
				self:sv_takeDamage( damage, "impact" )
			else
				self.network:sendToClients( "cl_n_onEvent", { event = "impact", pos = playerCharacter:getWorldPosition(), damage = damage * 0.01 } )
			end

			-- Melee impulse
			if attacker then
				ApplyKnockback( self.player.character, attackDirection, power )
			end
		end
	end
end

function SurvivalPlayer.server_onExplosion( self, center, destructionLevel )
	print("'SurvivalPlayer' took explosion damage")
	self:sv_takeDamage( destructionLevel * 2, "impact" )
	if self.player.character:isTumbling() then
		local knockbackDirection = ( self.player.character.worldPosition - center ):normalize()
		ApplyKnockback( self.player.character, knockbackDirection, 5000 )
	end
end

function SurvivalPlayer.sv_startTumble( self, tumbleTickTime )
	if not self.player.character:isDowned() and self.sv.resistTumbleTimer:done() then
		local currentTick = sm.game.getCurrentTick()
		self.sv.recentTumbles[#self.sv.recentTumbles+1] = currentTick
		local recentTumbles = {}
		for _, tumbleTickTimestamp in ipairs( self.sv.recentTumbles ) do
			if tumbleTickTimestamp >= currentTick - RecentTumblesTickTimeInterval then
				recentTumbles[#recentTumbles+1] = tumbleTickTimestamp
			end
		end
		self.sv.recentTumbles = recentTumbles
		if #self.sv.recentTumbles > MaxRecentTumbles then
			-- Too many tumbles in quick succession, gain temporary tumble immunity
			self.player.character:setTumbling( false )
			self.sv.maxTumbleTimer:reset()
			self.sv.tumbleReset:reset()
			self.sv.resistTumbleTimer:reset()
		else
			self.player.character:setTumbling( true )
			if tumbleTickTime then
				self.sv.tumbleReset:start( tumbleTickTime )
			else
				self.sv.tumbleReset:start( StopTumbleTimerTickThreshold )
			end
		end
	end
end

function SurvivalPlayer.sv_updateTumbling( self )
	if not self.sv.resistTumbleTimer:done() then
		self.sv.resistTumbleTimer:tick()
	end

	if not self.player.character:isDowned() then
		if self.player.character:isTumbling() then
			self.sv.maxTumbleTimer:tick()
			if self.sv.maxTumbleTimer:done() then
				-- Stuck in the tumble state for too long, gain temporary tumble immunity
				self.player.character:setTumbling( false )
				self.sv.maxTumbleTimer:reset()
				self.sv.tumbleReset:reset()
				self.sv.resistTumbleTimer:reset()
			else
				local tumbleVelocity = self.player.character:getTumblingLinearVelocity()
				if tumbleVelocity:length() < 1.0 then
					self.sv.tumbleReset:tick()

					if self.sv.tumbleReset:done() then
						self.player.character:setTumbling( false )
						self.sv.tumbleReset:reset()
					end
				else
					self.sv.tumbleReset:reset()
				end
			end
		end
	end
end

function SurvivalPlayer.sv_n_exchangeItem( self, params )
	if sm.container.beginTransaction() then
		sm.container.spendFromSlot( params.playerInventory, params.slotIndex, params.previousUid, params.previousQuantity, true )
		sm.container.collectToSlot( params.playerInventory, params.slotIndex, params.nextUid, params.nextQuantity, true )
		sm.container.endTransaction()
	end
end

function SurvivalPlayer.server_onCollision( self, other, collisionPosition, selfPointVelocity, otherPointVelocity, collisionNormal  )

	if not self.sv.impactCooldown:done() then
		return
	end

	local damageFraction, tumbleTicks = CharacterCollision( self, other, collisionPosition, selfPointVelocity, otherPointVelocity, collisionNormal )
	local damage = damageFraction * self.sv.saved.stats.maxhp
	if damage > 0 or tumbleTicks > 0 then
		self.sv.impactCooldown:start( 0.25 * 40 )
	end
	if damage > 0 then
		print("'SurvivalPlayer' took collision damage")
		self:sv_takeDamage( damage, "shock" )
	end
	if tumbleTicks > 0 then
		self:sv_startTumble( tumbleTicks )

		-- Apply a tumbling impulse based on the collision velocity
		local velocityDiff = selfPointVelocity - otherPointVelocity
		if velocityDiff:length() >= FLT_EPSILON then
			local impactSpeedDiff = math.abs( velocityDiff:dot( collisionNormal ) )
			local impactSpeedOther = math.abs( otherPointVelocity:dot( collisionNormal ) )
			local impactSpeed = math.min( impactSpeedDiff, impactSpeedOther )
			local impulseSpeed = math.min( impactSpeed * TumbleImpactImpulseFraction, MaxTumbleImpulseSpeed )
			local impulseVector = -velocityDiff:normalize() * impulseSpeed * self.player.character.mass
			self.player.character:applyTumblingImpulse( impulseVector )
		end
	end

end

function SurvivalPlayer.sv_e_staminaSpend( self, stamina )
	if not g_godMode then
		if stamina > 0 then
			self.sv.staminaSpend = self.sv.staminaSpend + stamina
			print( "SurvivalPlayer spent:", stamina, "stamina" )
		end
	else
		print( "SurvivalPlayer resisted", stamina, "stamina spend" )
	end
end

function SurvivalPlayer.sv_e_receiveDamage( self, damageData )
	self:sv_takeDamage( damageData.damage )
end

function SurvivalPlayer.sv_takeDamage( self, damage, source )
	if damage > 0 then
		local character = self.player:getCharacter()
		local lockingInteractable = character:getLockingInteractable()
		if lockingInteractable and lockingInteractable:hasSeat() then
			lockingInteractable:setSeatCharacter( character )
		end

		if not g_godMode and self.sv.damageCooldown:done() then
			if self.sv.saved.isConscious then
				self.sv.saved.stats.hp = math.max( self.sv.saved.stats.hp - damage, 0 )

				print( "'SurvivalPlayer' took:", damage, "damage.", self.sv.saved.stats.hp, "/", self.sv.saved.stats.maxhp, "HP" )

				if source then
					self.network:sendToClients( "cl_n_onEvent", { event = source, pos = character:getWorldPosition(), damage = damage * 0.01 } )
				else
					self.player:sendCharacterEvent( "hit" )
				end

				if self.sv.saved.stats.hp <= 0 then
					print( "'SurvivalPlayer' knocked out!" )
					self.sv.saved.isConscious = false
					character:setTumbling( true )
					character:setDowned( true )
				end

				self.storage:save( self.sv.saved )
				self.network:setClientData( self.sv.saved )
			end
		else
			print( "'SurvivalPlayer' resisted", damage, "damage" )
		end
	end
end

function SurvivalPlayer.sv_n_revive( self )
	local character = self.player:getCharacter()
	if not self.sv.saved.isConscious and self.sv.saved.hasRevivalItem and not self.sv.spawnparams.respawn then
		print( "SurvivalPlayer", self.player.id, "revived" )
		self.sv.saved.stats.hp = self.sv.saved.stats.maxhp
		self.sv.saved.stats.food = self.sv.saved.stats.maxfood
		self.sv.saved.stats.water = self.sv.saved.stats.maxwater
		self.sv.saved.isConscious = true
		self.sv.saved.hasRevivalItem = false
		self.storage:save( self.sv.saved )
		self.network:setClientData( self.sv.saved )
		sm.effect.playEffect( "Eat - EatFinish", self.player.character.worldPosition )
		if character then
			character:setTumbling( false )
			character:setDowned( false )
		end
		self.sv.damageCooldown:start( 40 )
		self.player:sendCharacterEvent( "revive" )
	end
end

function SurvivalPlayer.sv_e_respawn( self )
	if self.sv.spawnparams.respawn then
		if not self.sv.respawnTimeoutTimer then
			self.sv.respawnTimeoutTimer = Timer()
			self.sv.respawnTimeoutTimer:start( RespawnTimeout )
		end
		return
	end
	local character = self.player:getCharacter()
	if not self.sv.saved.isConscious then
		local lostItems = g_respawnManager:sv_performItemLoss( self.player )
		if lostItems then
			self.sv.spawnparams.lostItemsPosition = lostItems.worldPosition
		end
		self.sv.spawnparams.respawn = true
		sm.event.sendToGame( "sv_e_respawn", { player = self.player } )
	else
		print( "SurvivalPlayer must be unconscious to respawn" )
	end
end

function SurvivalPlayer.sv_n_respawn( self )
	self:sv_e_respawn()
end

function SurvivalPlayer.sv_onSpawnCharacter( self )
	if self.sv.saved.isNewPlayer then
		-- Intro cutscene for new player
		if not g_survivalDev then
			--self:sv_e_startLocalCutscene( "camera_approach_crash" )
		end
	elseif self.sv.spawnparams.respawn then
		local playerBed = g_respawnManager:sv_getPlayerBed( self.player )
		if playerBed and playerBed.shape and sm.exists( playerBed.shape ) and playerBed.shape.body:getWorld() == self.player.character:getWorld() then
			-- Attempt to seat the respawned character in a bed
			self.network:sendToClient( self.player, "cl_seatCharacter", { shape = playerBed.shape  } )
		else
			-- Respawned without a bed
			--self:sv_e_startLocalCutscene( "camera_wakeup_ground" )
		end
	end

	if self.sv.spawnparams.lostItemsPosition then
		self.network:sendToClient( self.player, "cl_addLostItemsMarker", { player = self.player, lostItemsPosition = self.sv.spawnparams.lostItemsPosition } )
	end

	if self.sv.saved.isNewPlayer or self.sv.spawnparams.respawn then
		print( "SurvivalPlayer", self.player.id, "spawned" )
		if self.sv.saved.isNewPlayer then
			self.sv.saved.stats.hp = self.sv.saved.stats.maxhp
			self.sv.saved.stats.food = self.sv.saved.stats.maxfood
			self.sv.saved.stats.water = self.sv.saved.stats.maxwater
		else
			self.sv.saved.stats.hp = 30
			self.sv.saved.stats.food = 30
			self.sv.saved.stats.water = 30
		end
		self.sv.saved.isConscious = true
		self.sv.saved.hasRevivalItem = false
		self.sv.saved.isNewPlayer = false
		self.storage:save( self.sv.saved )
		self.network:setClientData( self.sv.saved )

		self.player.character:setTumbling( false )
		self.player.character:setDowned( false )
		self.sv.damageCooldown:start( 40 )
	else
		-- SurvivalPlayer rejoined the game
		if self.sv.saved.stats.hp <= 0 or not self.sv.saved.isConscious then
			self.player.character:setTumbling( true )
			self.player.character:setDowned( true )
		end
	end

	self.sv.respawnTimeoutTimer = nil
	self.sv.spawnparams = {}
end

function SurvivalPlayer.cl_seatCharacter( self, params )
	if sm.exists( params.shape ) then
		params.shape.interactable:setSeatCharacter( self.player.character )
	end
end

function SurvivalPlayer.sv_e_debug( self, params )
	if params.hp then
		self.sv.saved.stats.hp = params.hp
	end
	if params.water then
		self.sv.saved.stats.water = params.water
	end
	if params.food then
		self.sv.saved.stats.food = params.food
	end
	self.storage:save( self.sv.saved )
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.sv_e_eat( self, edibleParams )
	if edibleParams.hpGain then
		self:sv_restoreHealth( edibleParams.hpGain )
	end
	if edibleParams.foodGain then
		self:sv_restoreFood( edibleParams.foodGain )
		sm.effect.playEffect( "Eat - EatFinish", self.player.character.worldPosition )
	end
	if edibleParams.waterGain then
		self:sv_restoreWater( edibleParams.waterGain )
		-- sm.effect.playEffect( "Eat - DrinkFinish", self.player.character.worldPosition )
	end
	self.storage:save( self.sv.saved )
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.sv_e_feed( self, params )
	if not self.sv.saved.isConscious and not self.sv.saved.hasRevivalItem then
		if sm.container.beginTransaction() then
			sm.container.spend( params.playerInventory, params.foodUuid, 1, true )
			if sm.container.endTransaction() then
				self.sv.saved.hasRevivalItem = true
				self.player:sendCharacterEvent( "baguette" )
				self.network:setClientData( self.sv.saved )
			end
		end
	end
end

function SurvivalPlayer.sv_restoreHealth( self, health )
	if self.sv.saved.isConscious then
		self.sv.saved.stats.hp = self.sv.saved.stats.hp + health
		self.sv.saved.stats.hp = math.min( self.sv.saved.stats.hp, self.sv.saved.stats.maxhp )
		print( "'SurvivalPlayer' restored:", health, "health.", self.sv.saved.stats.hp, "/", self.sv.saved.stats.maxhp, "HP" )
	end
end

function SurvivalPlayer.sv_restoreFood( self, food )
	if self.sv.saved.isConscious then
		food = food * ( 0.8 + ( self.sv.saved.stats.maxfood - self.sv.saved.stats.food ) / self.sv.saved.stats.maxfood * 0.2 )
		self.sv.saved.stats.food = self.sv.saved.stats.food + food
		self.sv.saved.stats.food = math.min( self.sv.saved.stats.food, self.sv.saved.stats.maxfood )
		print( "'SurvivalPlayer' restored:", food, "food.", self.sv.saved.stats.food, "/", self.sv.saved.stats.maxfood, "FOOD" )
	end
end

function SurvivalPlayer.sv_restoreWater( self, water )
	if self.sv.saved.isConscious then
		water = water * ( 0.8 + ( self.sv.saved.stats.maxwater - self.sv.saved.stats.water ) / self.sv.saved.stats.maxwater * 0.2 )
		self.sv.saved.stats.water = self.sv.saved.stats.water + water
		self.sv.saved.stats.water = math.min( self.sv.saved.stats.water, self.sv.saved.stats.maxwater )
		print( "'SurvivalPlayer' restored:", water, "water.", self.sv.saved.stats.water, "/", self.sv.saved.stats.maxwater, "WATER" )
	end
end

function SurvivalPlayer.sv_e_setRefiningState( self, params )
	local userPlayer = params.user:getPlayer()
	if userPlayer then
		if params.state == true then
			userPlayer:sendCharacterEvent( "refine" )
		else
			userPlayer:sendCharacterEvent( "refineEnd" )
		end
	end
end

function SurvivalPlayer.sv_e_onLoot( self, params )
	self.network:sendToClient( self.player, "cl_n_onLoot", params )
end

function SurvivalPlayer.cl_n_onLoot( self, params )
	local message = "Picked up "..sm.shape.getShapeTitle( params.uuid )
	if params.quantity > 1 then
		message = message.." x"..params.quantity
	end
	sm.gui.displayAlertText( message, 2 )
	sm.effect.playEffect( "Loot - Pickup", params.pos, sm.vec3.zero(), sm.quat.identity(), sm.vec3.one(), { ["Color"] = sm.shape.getShapeTypeColor( params.uuid ) } )
end

function SurvivalPlayer.sv_e_onMsg( self, msg )
	self.network:sendToClient( self.player, "cl_n_onMsg", msg )
end

function SurvivalPlayer.cl_n_onMsg( self, msg )
	sm.gui.displayAlertText( msg )
end

function SurvivalPlayer.sv_e_onStayPesticide( self )
	if self.sv.poisonDamageCooldown:done() then
		self:sv_takeDamage( PoisonDamage, "poison" )
		self.sv.poisonDamageCooldown:start( PoisonDamageCooldown )
	end
end

function SurvivalPlayer.sv_e_onEnterFire( self )
	if self.sv.fireDamageCooldown:done() then
		self:sv_takeDamage( FireDamage, "fire" )
		self.sv.fireDamageCooldown:start( FireDamageCooldown )
	end
end

function SurvivalPlayer.sv_e_onStayFire( self )
	if self.sv.fireDamageCooldown:done() then
		self:sv_takeDamage( FireDamage, "fire" )
		self.sv.fireDamageCooldown:start( FireDamageCooldown )
	end
end

function SurvivalPlayer.sv_e_onEnterChemical( self )
	if self.sv.poisonDamageCooldown:done() then
		self:sv_takeDamage( PoisonDamage, "poison" )
		self.sv.poisonDamageCooldown:start( PoisonDamageCooldown )
	end
	self.sv.saved.inChemical = true
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.sv_e_onStayChemical( self )
	if self.sv.poisonDamageCooldown:done() then
		self:sv_takeDamage( PoisonDamage, "poison" )
		self.sv.poisonDamageCooldown:start( PoisonDamageCooldown )
	end
end

function SurvivalPlayer.sv_e_onExitChemical( self )
	self.sv.saved.inChemical = false
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.server_onShapeRemoved( self, removedShapes )
	local numParts = 0
	local numBlocks = 0
	local numJoints = 0
	for _, removedShapeType in ipairs( removedShapes ) do
		if removedShapeType.type == "block"  then
			numBlocks = numBlocks + removedShapeType.amount
		elseif removedShapeType.type == "part"  then
			numParts = numParts + removedShapeType.amount
		elseif removedShapeType.type == "joint"  then
			numJoints = numJoints + removedShapeType.amount
		end
	end

	local staminaSpend = numParts + numJoints + math.sqrt( numBlocks )
	--self:sv_e_staminaSpend( staminaSpend )
end


-- Camera

function SurvivalPlayer.cl_updateCamera( self, dt )

	if self.useCutsceneCamera then
		local cameraPath = self.currentCutscene.cameraPath
		local cameraAttached = self.currentCutscene.cameraAttached
		if #cameraPath > 1 then
			if cameraPath[self.nodeIndex+1] then
				local prevNode = cameraPath[self.nodeIndex]
				local nextNode = cameraPath[self.nodeIndex+1]

				local prevPosition = prevNode.position
				local nextPosition = nextNode.position
				local prevDirection = prevNode.direction
				local nextDirection = nextNode.direction

				if prevNode.type == "playerSpace" then
					prevPosition = sm.camera.getDefaultPosition()
				end
				if nextNode.type == "playerSpace" then
					nextPosition = nextNode.position + sm.camera.getDefaultPosition()
					-- Set player to look in the same direction as the player node
					if cameraPath[self.nodeIndex].direction then
						sm.localPlayer.setDirection( cameraPath[self.nodeIndex+1].direction )
					end
				end

				if nextNode.lerpTime > 0 then
					self.progress = self.progress + dt / nextNode.lerpTime
				else
					self.progress = 1
				end

				if self.progress >= 1 then

					-- Trigger events in the next node
					if nextNode.events then
						for _, eventParams in pairs( nextNode.events ) do
							if eventParams.type == "character" then
								eventParams.character = self.player.character
							end
							self.network:sendToServer( "sv_onEvent", eventParams )
						end
					end

					self.nodeIndex = self.nodeIndex + 1
					local upcomingNextNode = cameraPath[self.nodeIndex+1]
					if upcomingNextNode then
						self.progress = ( self.progress - 1.0 ) * nextNode.lerpTime / upcomingNextNode.lerpTime
						self.progress = math.max( math.min( self.progress, 1.0 ), 0 )
						prevPosition = nextNode.position
						nextPosition = upcomingNextNode.position
						prevDirection = nextNode.direction
						nextDirection = upcomingNextNode.direction
						if nextNode.type == "playerSpace" then
							prevPosition = sm.camera.getDefaultPosition()
						end
						if upcomingNextNode.type == "playerSpace" then
							nextPosition = nextPosition +  sm.camera.getDefaultPosition()
							-- Set player to look in the same direction as the player node
							if cameraPath[self.nodeIndex].direction then
								sm.localPlayer.setDirection( cameraPath[self.nodeIndex+1].direction )
							end
						end
					else
						--Finished the cutscene
						self.progress = 0
						self.nodeIndex = 1
						if self.currentCutscene.nextCutscene then
							self:cl_startCutscene( camera_cutscenes[self.currentCutscene.nextCutscene] )
						else
							self.useCutsceneCamera = false
							sm.gui.hideGui( false )
							sm.camera.setCameraState( sm.camera.state.default )
							sm.localPlayer.setLockedControls( false )
						end
					end
				end

				local camPos = sm.vec3.lerp( prevPosition, nextPosition, self.progress )
				local camDir = sm.vec3.lerp( prevDirection, nextDirection, self.progress )

				sm.camera.setPosition( camPos )
				sm.camera.setDirection( camDir )
			end
		elseif cameraAttached then

			if self.progress >= 1 then
				--Finished the cutscene
				self.progress = 0
				self.nodeIndex = 1
				if self.currentCutscene.nextCutscene then
					self:cl_startCutscene( camera_cutscenes[self.currentCutscene.nextCutscene] )
				else
					self.useCutsceneCamera = false
					sm.gui.hideGui( false )
					sm.camera.setCameraState( sm.camera.state.default )
					sm.localPlayer.setLockedControls( false )
				end
			else
				local character = self.player:getCharacter()
				if character then
					sm.camera.setCameraState( sm.camera.state.cutsceneFP )
					local camPos = character:getTpBonePos( cameraAttached.jointName )
					local camDir = character:getTpBoneRot( cameraAttached.jointName ) * cameraAttached.initialDirection

					sm.camera.setPosition( camPos )
					sm.camera.setDirection( camDir )
				end
			end
			self.progress = self.progress + dt / cameraAttached.attachTime

		else
			self:cl_startCutscene( nil )
		end
	end

end


function SurvivalPlayer.cl_startCutscene( self, cutsceneInfo )
	if cutsceneInfo then
		self.useCutsceneCamera = true
		sm.gui.hideGui( true )
		sm.camera.setCameraState( cutsceneInfo.cameraState )
		if cutsceneInfo.cameraPullback then
			sm.camera.setCameraPullback( cutsceneInfo.cameraPullback.standing, cutsceneInfo.cameraPullback.seated )
		end

		sm.localPlayer.setLockedControls( true )

		if self.useCutsceneCamera then
			-- Set camera nodes to follow
			self.currentCutscene = {}
			self.currentCutscene.cameraAttached = cutsceneInfo.attached
			local cameraPath = {}
			local characterPosition = sm.vec3.new( 0, 0, 0 )
			local characterDirection = sm.vec3.new( 0, 1, 0 )
			local character = self.player.character
			if character then
				characterPosition = character.worldPosition + sm.vec3.new( 0, 0, character:getHeight() * 0.5 )
				characterDirection = character:getDirection()
			else
				characterPosition = sm.localPlayer.getRaycastStart()
				characterDirection = sm.localPlayer.getDirection()
			end

			-- Get character heading
			characterDirection.z = 0
			if characterDirection:length() >= FLT_EPSILON then
				characterDirection = characterDirection:normalize()
			else
				characterDirection = sm.vec3.new( 0, 1, 0 )
			end

			-- Prepare a world direction and positon for each camera node
			if cutsceneInfo.nodes then
				for _, node in pairs( cutsceneInfo.nodes ) do
					local updatedNode = {}
					if node.type == "localSpace" then
						local right = characterDirection:cross( sm.vec3.new( 0, 0, 1 ) )
						local pitchedDirection = sm.vec3.rotate( characterDirection, math.rad( node.pitch ), right )
						updatedNode.direction = sm.vec3.rotateZ( pitchedDirection, -math.rad( node.yaw ) )
						updatedNode.position = characterPosition + sm.vec3.getRotation( sm.vec3.new( 0, 1, 0 ), characterDirection ) * node.position
					elseif node.type == "playerSpace" then
						local right = sm.localPlayer.getDirection():cross( sm.vec3.new( 0, 0, 1 ) )
						local pitchedDirection = sm.vec3.rotate( sm.localPlayer.getDirection(), math.rad( node.pitch ), right )
						updatedNode.direction = sm.vec3.rotateZ( pitchedDirection, -math.rad( node.yaw ) )

						--updatedNode.position = sm.camera.getDefaultPosition() + sm.vec3.getRotation( sm.vec3.new( 0, 1, 0 ), sm.localPlayer.getDirection() ) * node.position
						updatedNode.position = sm.vec3.getRotation( sm.vec3.new( 0, 1, 0 ), sm.localPlayer.getDirection() ) * node.position
					else
						updatedNode.position = node.position
						updatedNode.direction = node.direction
					end
					updatedNode.type = node.type
					updatedNode.lerpTime = node.lerpTime
					updatedNode.events = node.events
					cameraPath[#cameraPath+1] = updatedNode
				end
			end

			if #cameraPath > 0 then
				-- Trigger events in the first node
				if cameraPath[1] then
					if cameraPath[1].events then
						for _, eventParams in pairs( cameraPath[1].events ) do
							if eventParams.type == "character" then
								eventParams.character = self.player.character
							end
							self.network:sendToServer( "sv_onEvent", eventParams )
						end
					end
				end
			elseif self.currentCutscene.cameraAttached then
				-- Trigger events
				if self.currentCutscene.cameraAttached.events then
					for _, eventParams in pairs( self.currentCutscene.cameraAttached.events ) do
						if eventParams.type == "character" then
							eventParams.character = self.player.character
						end
						self.network:sendToServer( "sv_onEvent", eventParams )
					end
				end
			end

			self.currentCutscene.cameraPath = cameraPath
			self.currentCutscene.nextCutscene = cutsceneInfo.nextCutscene
			self.currentCutscene.canSkip = cutsceneInfo.canSkip
		end
	else
		self.useCutsceneCamera = false
		sm.gui.hideGui( false )
		sm.camera.setCameraState( sm.camera.state.default )
		sm.localPlayer.setLockedControls( false )
		self.progress = 0
		self.nodeIndex = 1
	end
end

function SurvivalPlayer.cl_startLocalCutscene( self, params )
	if params.player == sm.localPlayer.getPlayer() then
		self:cl_startCutscene( camera_cutscenes[params.cutsceneInfoName] )
	end
end

function SurvivalPlayer.sv_e_startLocalCutscene( self, cutsceneInfoName )
	local params = { player = self.player, cutsceneInfoName = cutsceneInfoName }
	self.network:sendToClients( "cl_startLocalCutscene", params )
end

function SurvivalPlayer.sv_onEvent( self, eventParams )
	if eventParams.type == "character" then
		self.player:sendCharacterEvent( eventParams.data )
	end
end


function SurvivalPlayer.client_onCancel( self )

	if self.useCutsceneCamera and self.currentCutscene.canSkip then
		if self.currentCutscene.nextCutscene then
			self:cl_startCutscene( camera_cutscenes[self.currentCutscene.nextCutscene] )
		else
			self.useCutsceneCamera = false
			sm.gui.hideGui( false )
			sm.camera.setCameraState( sm.camera.state.default )
			sm.localPlayer.setLockedControls( false )
			self.progress = 0
			self.nodeIndex = 1
		end
	end
	
end

function SurvivalPlayer.client_onReload( self ) end