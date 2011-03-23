package com.increpare.bfxr.synthesis.Mixer
{
	import com.increpare.bfxr.synthesis.IPlayerInterface;
	import com.increpare.bfxr.synthesis.ISerializable;
	import com.increpare.bfxr.synthesis.Synthesizer.SfxrSynth;
	import com.increpare.bfxr.synthesis.WaveWriter;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.SampleDataEvent;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.utils.ByteArray;
	import flash.utils.Endian;

	public class MixerPlayer extends EventDispatcher implements ISerializable
	{
		public var id:int = -1;
		public var volume:Number = 1;
		public var tracks:Vector.<MixerTrackPlayer>;
		
		public function MixerPlayer() 
		{
			tracks = new Vector.<MixerTrackPlayer>();
			for (var i:int=0;i<MixerSynth.TRACK_COUNT;i++)
			{
				var mtp:MixerTrackPlayer = new MixerTrackPlayer();
				tracks.push(mtp);
			}		
			
			if (_zeros==null)
			{				
				_zeros = new ByteArray();
				for (i=0;i<400000;i++)
				{
					_zeros.writeFloat(0.0);
				}
			}
		}
		
		public static function Reverse(ba:ByteArray):ByteArray
		{
			var result:ByteArray = new ByteArray();
			var l:uint=ba.length;
			//subtract 8 because reading a float each time :P
			for (ba.position=ba.length-4;ba.position<ba.length;ba.position-=8)
			{
				result.writeFloat(ba.readFloat());
			}
			return result;
		}
				
		public function Serialize():String
		{
			var result:String="";
			result += id.toString() + ">";
			result += volume.toString() + ">";
			for (var i:int=0;i<tracks.length;i++)
			{
				if (i>0)
					result+=">";
				
				result += tracks[i].Serialize();
			}
			return result;
		}
		
		public function Deserialize(settings:String):void
		{
			var ar:Array = settings.split(">");
			id = int(ar[0]);
			volume = Number(ar[1]);
			for (var i:int=2;i<ar.length;i++)
			{
				var s:String = ar[i];
				tracks[i-2].Deserialize(s);
			}
		}
				
		private var _updateCallback:Function=null;
		private var _lastplayeddata:String="";
		private var _caching:Boolean=false;
		private var _channel:SoundChannel;
		private var _sound:Sound;
		private var _waveData:ByteArray;
		private var _waveDataLength:int=-1;
		private var _waveDataBytes:int=-1;
		private var _waveDataPos:uint=0;
		private var _preparedsounds:Vector.<ByteArray>;
		private var _preparedvolumes:Vector.<Number>; //stores corresponding volumes
		private static var _zeros:ByteArray;
		
		private function PrepareMixForPlay():void
		{
			var description:String = this.Serialize();
			if (_lastplayeddata!=description)
			{
				_lastplayeddata = description;
				
				//copy tracks over and add whitespace
				_preparedsounds = new Vector.<ByteArray>();
				_preparedvolumes = new Vector.<Number>();
				for (var i:int=0;i<tracks.length;i++)
				{
					if (tracks[i].IsSet()==false)
					{
						continue;
					}
					
					var b:ByteArray = new ByteArray();
					
					var silentbytes:int = int(tracks[i].data.onset*44100/2)*4*2;//ensure multiple of 8...
					
					// create starting silence.
					while(silentbytes>0)
					{
						var bytestocopy:int=Math.min(silentbytes,_zeros.length);
						
						b.writeBytes(_zeros,0,bytestocopy);
						
						silentbytes-=bytestocopy;
					}
					
					var cached:ByteArray = tracks[i].synth.cachedWave;
					if (tracks[i].data.reverse)
					{
						cached=Reverse(cached);
					}
					
					b.writeBytes(cached);
					
					b.position=0;
					_preparedsounds.push(b);
					_preparedvolumes.push(tracks[i].data.volume);
				}
				
				Mix();
			}		
		}
		
		public function play(updateCallback:Function=null):void
		{
			_updateCallback=updateCallback;
			
			PrepareMixForPlay();	
			
			if (_preparedsounds.length==0)
			{
				return;
			}
			
			if (_channel)
			{
				_channel.stop();
			}
			
			_waveData.position = 0;
			_waveDataLength = _waveData.length;
			_waveDataBytes = 24576;
			_waveDataPos = 0; 	
			_caching=true;
			if (!_sound) (_sound = new Sound()).addEventListener(SampleDataEvent.SAMPLE_DATA, onSoundData);
			
			_channel = _sound.play();
		}
		
		public function stop():void
		{
			if (_channel)
			{
				_channel.stop();
				_channel = null;
			}
		}
		
		/**
		 * Returns a ByteArray of the wave in the form of a .wav file, ready to be saved out
		 * @param	sampleRate		Sample rate to generate the .wav at	
		 * @param	bitDepth		Bit depth to generate the .wav at	
		 * @return					Wave in a .wav file
		 */
		public function getWavFile():ByteArray
		{
			stop();			
			
			PrepareMixForPlay();			
			
			var ww:WaveWriter = new WaveWriter(true,32);
			
			ww.addSamples(_waveData);
			ww.finalize();
			
			return ww.outBuffer;
		}
				
		/** param is whether to work in bytes, shorts, or floats (1,2,4)*/
		private function Mix(unitsize:int=4):void
		{
			var trackcount:int=_preparedsounds.length;
			_waveData = new ByteArray();
						
			var added:Boolean=true;
			
			var i:int;
			
			switch(unitsize)
			{
				case 1:
					while (added)
					{
						added=false;
						var val:int=0;
						for (i=0;i<trackcount;i++)
						{
							if (_preparedsounds[i].position<_preparedsounds[i].length-unitsize)
							{
								val += _preparedsounds[i].readByte()*_preparedvolumes[i];
								added=true;
							}
						}
						
						val*=volume;
						
						if (val >= (1<<7))
							val=1<<7;
						if (val<= -(1<<7))
							val=-(1<<7);
						
						_waveData.writeByte(val);
					}
					break;
				case 2:
					while (added)
					{
						added=false;
						val=0;
						for (i=0;i<trackcount;i++)
						{
							if (_preparedsounds[i].position<_preparedsounds[i].length-unitsize)
							{
								val += _preparedsounds[i].readShort()*_preparedvolumes[i];
								added=true;
							}
						}
						
						val*=volume;						
						
						if (val >= (1<<15))
							val=1<<15;
						if (val<= -(1<<15))
							val=-(1<<15);
						
						_waveData.writeShort(val);
					}
					break;
				case 4:
					while (added)
					{
						added=false;
						var valf:Number=0;
						for (i=0;i<trackcount;i++)
						{
							if (_preparedsounds[i].position<_preparedsounds[i].length-unitsize)
							{
								valf += _preparedsounds[i].readFloat()*_preparedvolumes[i];
								added=true;
							}
						}
						
						valf*=volume;
						
						_waveData.writeFloat(valf);
					}
					break;
			}
			
			_waveData.position=0;
		}
						
		private function onSoundData(e:SampleDataEvent) : void
		{					
			if (_caching)
			{
				if (_updateCallback!=null)
				{
					_updateCallback(_waveDataPos/(4*44100));
				}
				
				if(_waveDataPos + _waveDataBytes > _waveDataLength)
				{
					_waveDataBytes = _waveDataLength - _waveDataPos;
					dispatchEvent(new Event(SfxrSynth.PLAY_COMPLETE));	
				}
				
				if(_waveDataBytes > 0) e.data.writeBytes(_waveData, _waveDataPos, _waveDataBytes);
				
				//if too short..append data
				if (e.data.position<24576) 
				{
					_caching=false;
					while (e.data.position<24576)
					{
						e.data.writeFloat(0.0);
					}
				}
				
				_waveDataPos += _waveDataBytes;	
			}
		}
			
	
	}
}